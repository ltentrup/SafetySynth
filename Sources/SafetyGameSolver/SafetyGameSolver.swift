import CAiger
import CAigerHelper
import Aiger
import CUDD


public class SafetyGameSolver {
    let instance: SafetyGame
    let manager: CUDDManager
    
    var exiscube: CUDDNode
    var univcube: CUDDNode
    
    public init(instance: SafetyGame) {
        self.instance = instance
        self.manager = instance.manager
        
        self.exiscube = manager.one()
        self.univcube = manager.one()
        
        exiscube = instance.controllables.reduce(manager.one(), { f, node in f & node })
        univcube = instance.uncontrollables.reduce(manager.one(), { f, node in f & node })
    }
    
    func getStates(function: CUDDNode) -> CUDDNode {
        let abstracted = function.ExistAbstract(cube: exiscube)
        return abstracted.UnivAbstract(cube: univcube)
    }
    
    func preSystem(states: CUDDNode) -> CUDDNode {
        return states.compose(vector: instance.compose)
            .AndAbstract(with: instance.output, cube: exiscube)
            .UnivAbstract(cube: univcube)
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
        guard let synthesized = aiger_init() else {
            exit(1)
        }
        
        // make sure that it only contains non-negated nodes
        var nodeIndexToAig: [Int:AigerLit] = [:]
        var bddToAig: [CUDDNode:AigerLit] = [manager.one():1]
        
        for (uncontrollable, origLit) in zip(instance.uncontrollables, instance.uncontrollableNames) {
            let lit = aiger_next_lit(synthesized)
            aiger_add_input(synthesized, lit, String(origLit))
            bddToAig[uncontrollable] = lit
            nodeIndexToAig[uncontrollable.index()] = lit
        }
        
        for (latch, origLit) in zip(instance.latches, instance.latchNames) {
            let lit = aiger_next_lit(synthesized)
            aiger_add_input(synthesized, lit, String(origLit))
            bddToAig[latch] = lit
            nodeIndexToAig[latch.index()] = lit
        }
        
        for (strategy, origLit) in zip(strategies, instance.controllableNames) {
            aiger_add_output(synthesized, translateBddToAig(synthesized, cache: &bddToAig, nodeTransform: nodeIndexToAig, node: strategy), String(origLit))
        }
        
        aiger_reencode(synthesized)
        //aiger_write_to_file(synthesized, aiger_ascii_mode, stdout)
        
        return synthesized
    }
    
    func getStrategiesFrom(winningRegion: CUDDNode) -> [CUDDNode] {
        // ∀ x,i ∃ o (safe ∧ winning')
        let careSet = winningRegion.copy()
        var nondeterministicStrategy = winningRegion.compose(vector: instance.compose) & instance.output
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
    
    public func printWinningRegion(winningRegion: CUDDNode) {
        // print winning region as AIGER circuit:
        // latches are inputs and it has exactly one output that is one iff states are in winning region
        guard let winningRegionCircuit = aiger_init() else {
            exit(1)
        }
        print("\nWINNING_REGION")
        
        // make sure that it only contains non-negated nodes
        var nodeIndexToAig: [Int:AigerLit] = [:]
        var bddToAig: [CUDDNode:AigerLit] = [manager.one():1]
        
        for latch in instance.latches {
            let lit = aiger_next_lit(winningRegionCircuit)
            aiger_add_input(winningRegionCircuit, lit, nil)
            bddToAig[latch] = lit
            nodeIndexToAig[latch.index()] = lit
        }
        aiger_add_output(winningRegionCircuit, translateBddToAig(winningRegionCircuit, cache: &bddToAig, nodeTransform: nodeIndexToAig, node: winningRegion), "winning region")
        aiger_write_to_file(winningRegionCircuit, aiger_ascii_mode, stdout)
    }
}
