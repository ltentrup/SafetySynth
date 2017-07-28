import CAiger
import CAigerHelper
import Aiger
import CUDD


public class SafetyGameSolver {
    let instance: SafetyGame
    let manager: CUDDManager
    let mealy: Bool
    
    var exiscube: CUDDNode
    var univcube: CUDDNode
    
    public init(instance: SafetyGame, mealy: Bool = true) {
        self.instance = instance
        self.manager = instance.manager
        self.mealy = mealy
        
        self.exiscube = manager.one()
        self.univcube = manager.one()
        
        exiscube = instance.controllables.reduce(manager.one(), { f, node in f & node })
        univcube = instance.uncontrollables.reduce(manager.one(), { f, node in f & node })
    }
    
    func preSystem(states: CUDDNode) -> CUDDNode {
        if mealy {
            return states.compose(vector: instance.compose)
                         .AndAbstract(with: instance.safetyCondition, cube: exiscube)
                         .UnivAbstract(cube: univcube)
        } else {
            return (states.compose(vector: instance.compose) & instance.safetyCondition)
                   .UnivAbstract(cube: univcube)
                   .ExistAbstract(cube: exiscube)
        }
    }
    
    public func solve() -> CUDDNode? {
        var fixpoint = manager.zero()
        var safeStates = manager.one()
        
        var rounds = 0
        while safeStates != fixpoint {
            rounds += 1
            //print("Round \(rounds)")
            fixpoint = safeStates.copy()
            safeStates &= preSystem(states: safeStates)
            if !(instance.initial <= safeStates) {
                // unrealizable
                return nil
            }
        }
        return fixpoint
    }
    
    public func synthesize(winningRegion: CUDDNode) -> UnsafeMutablePointer<aiger> {
        
        let strategies: [CUDDNode] = getStrategiesFrom(winningRegion: winningRegion)
        
        // create aiger output
        // the output has the following format:
        // inputs: previous uncontrollable inputs and latches
        // outputs: previous controllable inputs
        // the uncontrollable inputs, latches, and controllable inputs are defined in the original order to faciliate matching afterwards
        let aigerEncoder = BDD2AigerEncoder(manager: manager)
        
        for (uncontrollable, origLit) in zip(instance.uncontrollables, instance.uncontrollableNames) {
            aigerEncoder.addInput(node: uncontrollable, name: String(origLit))
        }
        
        for (latch, origLit) in zip(instance.latches, instance.latchNames) {
            aigerEncoder.addInput(node: latch, name: String(origLit))
        }
        
        for (strategy, origLit) in zip(strategies, instance.controllableNames) {
            aigerEncoder.addOutput(node: strategy, name: String(origLit))
        }
        
        //aiger_write_to_file(synthesized, aiger_ascii_mode, stdout)
        
        return aigerEncoder.aiger
    }
    
    public func getStrategiesFrom(winningRegion: CUDDNode) -> [CUDDNode] {
        // ∀ x,i ∃ o (safe ∧ winning')
        let careSet = winningRegion.copy()
        var nondeterministicStrategy = winningRegion.compose(vector: instance.compose) & instance.safetyCondition
        var strategies: [CUDDNode] = []
        for controllable in instance.controllables {
            var winningControllable = nondeterministicStrategy.copy()
            let otherControllables = instance.controllables.filter({ c in c != controllable})
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

    public func printWinningRegion(winningRegion: CUDDNode) {
        // print winning region as AIGER circuit:
        // latches are inputs and it has exactly one output that is one iff states are in winning region
        print("\nWINNING_REGION")
        
        let aigerEncoder = BDD2AigerEncoder(manager: manager)
        
        for latch in instance.latches {
            aigerEncoder.addInput(node: latch, name: "")
        }
        aigerEncoder.addOutput(node: winningRegion, name: "winning region")

        let winningRegionCircuit = aigerEncoder.aiger
        aiger_write_to_file(winningRegionCircuit, aiger_ascii_mode, stdout)
    }
}

public class BDD2AigerEncoder {
    let manager: CUDDManager
    
    var nodeIndexToAig: [Int:AigerLit]
    var bddToAig: [CUDDNode:AigerLit]
    
    let aig: UnsafeMutablePointer<aiger>
    
    public var aiger: UnsafeMutablePointer<aiger> {
        aiger_reencode(aig)
        return aig
    }
    
    public init(manager: CUDDManager) {
        self.manager = manager
        
        self.nodeIndexToAig = [:]
        self.bddToAig = [manager.one():1]
        
        guard let aiger = aiger_init() else {
            fatalError()
        }
        self.aig = aiger
    }
    
    public func addInput(node: CUDDNode, name: String) {
        let lit = aiger_next_lit(aig)
        aiger_add_input(aig, lit, name)
        bddToAig[node] = lit
        nodeIndexToAig[node.index()] = lit
    }
    
    public func addLatchVariable(node: CUDDNode) {
        let lit = aiger_next_lit(aig)
        aiger_add_latch(aig, lit, 0, nil)
        bddToAig[node] = lit
        nodeIndexToAig[node.index()] = lit
    }
    
    public func defineLatch(node: CUDDNode, nextNode: CUDDNode) {
        guard let lit = nodeIndexToAig[node.index()] else {
            fatalError()
        }
        guard let symbol = aiger_is_latch(aig, lit) else {
            fatalError()
        }
        symbol.pointee.next = translateBddToAig(node: nextNode)
    }
    
    public func addOutput(node: CUDDNode, name: String) {
        aiger_add_output(aig, translateBddToAig(node: node), name)
    }
    
    func normalizeBddNode(_ node: CUDDNode) -> (Bool, CUDDNode) {
        return node.isComplement() ? (true, !node) : (false, node)
    }
    
    func translateBddToAig(node: CUDDNode) -> UInt32 {
        let (negated, node) = normalizeBddNode(node)
        assert(!node.isComplement())
        if let lookup = bddToAig[node] {
            return negated ? aiger_not(lookup) : lookup
        }
        assert(node != manager.one())
        
        guard let nodeLit = nodeIndexToAig[node.index()] else {
            fatalError()
        }
        
        let thenLit = translateBddToAig(node: node.thenChild())
        let elseLit = translateBddToAig(node: node.elseChild())
        
        // ite(node, then_child, else_child)
        // = node*then_child + !node*else_child
        // = !(!(node*then_child) * !(!node*else_child))
        
        let leftAnd = aiger_create_and(aig, lhs: nodeLit, rhs: thenLit)
        let rightAnd = aiger_create_and(aig, lhs: aiger_not(nodeLit), rhs: elseLit)
        let iteLit = aiger_not(aiger_create_and(aig, lhs: aiger_not(leftAnd), rhs: aiger_not(rightAnd)))
        bddToAig[node] = iteLit
        return negated ? aiger_not(iteLit) : iteLit
    }
}

