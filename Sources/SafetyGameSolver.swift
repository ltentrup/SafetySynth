import CAiger
import CAigerHelper
import Aiger
import CUDD


class SafetyGameSolver {
    let instance: SafetyGame
    
    let manager: CUDDManager
    var cache: [AigerLit:CUDDNode]
    
    let controllables: [CUDDNode]
    let uncontrollables: [CUDDNode]
    let latches: [CUDDNode]
    var compose: [CUDDNode]
    
    var initial: CUDDNode
    var output: CUDDNode
    var exiscube: CUDDNode
    var univcube: CUDDNode
    
    init(instance: SafetyGame) {
        self.instance = instance
        
        let copy = aiger_copy(self.instance.representation.aiger)!
        aiger_reencode(copy)
        let copyOverlay = Aiger(from: copy, resetOnDealloc: true)
        
        manager = CUDDManager()
        manager.AutodynEnable(reorderingAlgorithm: .GroupSift)
        cache = [0:manager.zero()]
        
        var controllables: [CUDDNode] = []
        var uncontrollables: [CUDDNode] = []
        var latches: [CUDDNode] = []
        self.compose = []
        
        for symbol in copyOverlay.inputs {
            let node = manager.newVar()
            cache[symbol.lit] = node
            let name: String = String(cString: symbol.name)
            if name.hasPrefix("controllable_") {
                controllables.append(node)
            } else {
                uncontrollables.append(node)
            }
            compose.append(node)
            node.setPrimaryInput()
        }
        
        assert(controllables.count == instance.controllableLits.count)
        assert(uncontrollables.count == instance.uncontrollableLits.count)
        
        for symbol in copyOverlay.latches {
            let node = manager.newVar()
            node.setPresentState()
            cache[symbol.lit] = node
            latches.append(node)
        }
        
        assert(latches.count == instance.latchLits.count)
        
        self.controllables = controllables
        self.uncontrollables = uncontrollables
        self.latches = latches
        self.initial = manager.one()
        self.output = manager.one()
        self.exiscube = manager.one()
        self.univcube = manager.one()
        
        var andPtr = copy.pointee.ands
        for _ in 0..<copy.pointee.num_ands {
            let and = andPtr!.pointee
            andPtr = andPtr?.successor()
            cache[and.lhs] = lookupLiteral(node: and.rhs0) & lookupLiteral(node: and.rhs1)
        }
        
        for latch in latches {
            initial &= !latch
        }
        
        for symbol in copyOverlay.latches {
            let function = lookupLiteral(node: symbol.next)
            compose.append(function)
        }
        
        for symbol in copyOverlay.outputs {
            output &= !lookupLiteral(node: symbol.lit)
        }
        
        // reset cache (dereferences contained BDDs)
        cache = [:]
        
        exiscube = controllables.reduce(manager.one(), { f, node in f & node })
        univcube = uncontrollables.reduce(manager.one(), { f, node in f & node })
    }
    
    func lookupLiteral(node: AigerLit) -> CUDDNode {
        let (negated, normalizedNode) = aiger_normalize(node)
        guard let bddNode = cache[normalizedNode] else {
            print("error: lookup of \(node) failed")
            exit(1)
        }
        return negated ? !bddNode : bddNode
    }
    
    func getStates(function: CUDDNode) -> CUDDNode {
        let abstracted = function.ExistAbstract(cube: exiscube)
        return abstracted.UnivAbstract(cube: univcube)
    }
    
    func preSystem(states: CUDDNode) -> CUDDNode {
        return states.compose(vector: compose)
            .AndAbstract(with: output, cube: exiscube)
            .UnivAbstract(cube: univcube)
    }
    
    func solve() -> CUDDNode? {
        var fixpoint = manager.zero()
        var safeStates = manager.one()
        
        var rounds = 0
        while safeStates != fixpoint {
            rounds += 1
            //print("Round \(rounds)")
            fixpoint = safeStates.copy()
            safeStates &= preSystem(states: safeStates)
            if !(initial <= safeStates) {
                // unrealizable
                return nil
            }
        }
        return fixpoint
    }
    
    func synthesize(winningRegion: CUDDNode) -> UnsafeMutablePointer<aiger> {
        
        let strategies: [CUDDNode] = getStrategiesFrom(winningRegion: winningRegion)
        
        // create aiger output
        // the output has the following format:
        // inputs: previous uncontrollable inputs and latches
        // outputs: previous controllable inputs
        // the uncontrollable inputs, latches, and controllable inputs are defined in the original order to faciliate matching afterwards
        guard let synthesized = aiger_init() else {
            exit(1)
        }
        
        // make sure that it only contains non-negated nodes
        var nodeIndexToAig: [Int:AigerLit] = [:]
        var bddToAig: [CUDDNode:AigerLit] = [manager.one():1]
        
        for (uncontrollable, origLit) in zip(uncontrollables, instance.uncontrollableLits) {
            let lit = aiger_next_lit(synthesized)
            aiger_add_input(synthesized, lit, String(origLit))
            bddToAig[uncontrollable] = lit
            nodeIndexToAig[uncontrollable.index()] = lit
        }
        
        for (latch, origLit) in zip(latches, instance.latchLits) {
            let lit = aiger_next_lit(synthesized)
            aiger_add_input(synthesized, lit, String(origLit))
            bddToAig[latch] = lit
            nodeIndexToAig[latch.index()] = lit
        }
        
        for (strategy, origLit) in zip(strategies, instance.controllableLits) {
            aiger_add_output(synthesized, translateBddToAig(synthesized, cache: &bddToAig, nodeTransform: nodeIndexToAig, node: strategy), String(origLit))
        }
        
        aiger_reencode(synthesized)
        //aiger_write_to_file(synthesized, aiger_ascii_mode, stdout)
        
        return synthesized
    }
    
    func getStrategiesFrom(winningRegion: CUDDNode) -> [CUDDNode] {
        // ∀ x,i ∃ o (safe ∧ winning')
        let careSet = winningRegion.copy()
        var nondeterministicStrategy = winningRegion.compose(vector: compose) & output
        var strategies: [CUDDNode] = []
        for controllable in controllables {
            var winningControllable = nondeterministicStrategy.copy()
            let otherControllables = controllables.filter({ c in c != controllable})
            if otherControllables.count > 0 {
                winningControllable = winningControllable.ExistAbstract(cube: otherControllables.reduce(manager.one(), { f, node in f & node }))
            }
            // moves (x, i) where controllable can appear positively, respectively negatively
            let canBeTrue = winningControllable.coFactor(withRespectTo: controllable)
            let canBeFalse = winningControllable.coFactor(withRespectTo: !controllable)
            let mustBeTrue = !canBeFalse & canBeTrue
            let mustBeFalse = !canBeTrue & canBeFalse
            let localCareSet = careSet & (mustBeTrue | mustBeFalse)
            let model_true = mustBeTrue.restrict(with: localCareSet)
            let model_false = (!mustBeFalse).restrict(with: localCareSet)
            let model: CUDDNode
            if model_true.dagSize() < model_false.dagSize() {
                model = model_true
            } else {
                model = model_false
            }
            strategies.append(model)
            //print("strategy has size \(model.dagSize())")
            nondeterministicStrategy &= (controllable <-> model)
        }
        return strategies
    }
    
    func normalizeBddNode(_ node: CUDDNode) -> (Bool, CUDDNode) {
        return node.isComplement() ? (true, !node) : (false, node)
    }
    
    func translateBddToAig(_ aig: UnsafeMutablePointer<aiger>, cache: inout [CUDDNode:UInt32], nodeTransform: [Int:UInt32], node: CUDDNode) -> UInt32 {
        let (negated, node) = normalizeBddNode(node)
        assert(!node.isComplement())
        if let lookup = cache[node] {
            return negated ? aiger_not(lookup) : lookup
        }
        assert(node != manager.one())
        
        guard let nodeLit = nodeTransform[node.index()] else {
            exit(1)
        }
        
        let thenLit = translateBddToAig(aig, cache: &cache, nodeTransform: nodeTransform, node: node.thenChild())
        let elseLit = translateBddToAig(aig, cache: &cache, nodeTransform: nodeTransform, node: node.elseChild())
        
        // ite(node, then_child, else_child)
        // = node*then_child + !node*else_child
        // = !(!(node*then_child) * !(!node*else_child))
        
        let leftAnd = aiger_create_and(aig, lhs: nodeLit, rhs: thenLit)
        let rightAnd = aiger_create_and(aig, lhs: aiger_not(nodeLit), rhs: elseLit)
        let iteLit = aiger_not(aiger_create_and(aig, lhs: aiger_not(leftAnd), rhs: aiger_not(rightAnd)))
        cache[node] = iteLit
        return negated ? aiger_not(iteLit) : iteLit
    }
    
    func printWinningRegion(winningRegion: CUDDNode) {
        // print winning region as AIGER circuit:
        // latches are inputs and it has exactly one output that is one iff states are in winning region
        guard let winningRegionCircuit = aiger_init() else {
            exit(1)
        }
        print("\nWINNING_REGION")
        
        // make sure that it only contains non-negated nodes
        var nodeIndexToAig: [Int:AigerLit] = [:]
        var bddToAig: [CUDDNode:AigerLit] = [manager.one():1]
        
        for latch in latches {
            let lit = aiger_next_lit(winningRegionCircuit)
            aiger_add_input(winningRegionCircuit, lit, nil)
            bddToAig[latch] = lit
            nodeIndexToAig[latch.index()] = lit
        }
        aiger_add_output(winningRegionCircuit, translateBddToAig(winningRegionCircuit, cache: &bddToAig, nodeTransform: nodeIndexToAig, node: winningRegion), "winning region")
        aiger_write_to_file(winningRegionCircuit, aiger_ascii_mode, stdout)
    }
}
