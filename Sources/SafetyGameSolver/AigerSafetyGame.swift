import CAiger
import CAigerHelper
import Aiger
import CUDD

public protocol SafetyGame {
    var manager: CUDDManager { get }
    var controllables: [CUDDNode] { get }
    var uncontrollables: [CUDDNode] { get }
    var latches: [CUDDNode] { get }
    var compose: [CUDDNode] { get }
    var initial: CUDDNode { get }
    
    /**
     * The output is 1 iff the safety condition is satisfied
     */
    var safetyCondition: CUDDNode { get }
    
    var controllableNames: [String] { get }
    var uncontrollableNames: [String] { get }
    var latchNames: [String] { get }
}

typealias AigerLit = UInt32

public struct AigerSafetyGame: SafetyGame {
    public let manager: CUDDManager
    
    public var controllables: [CUDDNode]
    public var uncontrollables: [CUDDNode]
    public var latches: [CUDDNode]
    
    public var compose: [CUDDNode]
    public var initial: CUDDNode
    public var safetyCondition: CUDDNode
    
    let representation: Aiger
    
    public var controllableNames: [String]
    public var uncontrollableNames: [String]
    public var latchNames: [String]
    
    public init(using manager: CUDDManager, from: Aiger) {
        self.manager = manager
        self.representation = from
        
        var controllableLits: [AigerLit] = []
        var uncontrollableLits: [AigerLit] = []
        
        for symbol in from.inputs {
            let name: String = String(cString: symbol.name)
            if name.hasPrefix("controllable_") {
                controllableLits.append(symbol.lit)
            } else {
                uncontrollableLits.append(symbol.lit)
            }
        }
        
        self.controllableNames = controllableLits.map({ String($0) })
        self.uncontrollableNames = uncontrollableLits.map({ String($0) })
        self.latchNames = from.latches.map({ String($0.lit) })
        
        var cache: [AigerLit:CUDDNode]
        
        let copy = aiger_copy(self.representation.aiger)!
        aiger_reencode(copy)
        let copyOverlay = Aiger(from: copy, resetOnDealloc: true)
        
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
        
        assert(controllables.count == controllableLits.count)
        assert(uncontrollables.count == uncontrollableLits.count)
        
        for symbol in copyOverlay.latches {
            let node = manager.newVar()
            node.setPresentState()
            cache[symbol.lit] = node
            latches.append(node)
        }
        
        self.controllables = controllables
        self.uncontrollables = uncontrollables
        self.latches = latches
        self.initial = manager.one()
        self.safetyCondition = manager.one()
        
        assert(latches.count == latchNames.count)
        
        func lookupLiteral(node: AigerLit) -> CUDDNode {
            let (negated, normalizedNode) = aiger_normalize(node)
            guard let bddNode = cache[normalizedNode] else {
                print("error: lookup of \(node) failed")
                exit(1)
            }
            return negated ? !bddNode : bddNode
        }
        
        var andPtr = copy.pointee.ands
        for _ in 0..<copy.pointee.num_ands {
            let and = andPtr!.pointee
            andPtr = andPtr?.successor()
            cache[and.lhs] = lookupLiteral(node: and.rhs0) & lookupLiteral(node: and.rhs1)
        }
        
        for (node, latch) in zip(latches, copyOverlay.latches) {
            if latch.reset == 0 {
                initial &= !node
            } else if latch.reset == 1 {
                initial &= node
            } else {
                fatalError("error in AIGER input: only 0 and 1 is allowed for initial latch values")
            }
        }
        
        for symbol in copyOverlay.latches {
            let function = lookupLiteral(node: symbol.next)
            compose.append(function)
        }
        
        for symbol in copyOverlay.outputs {
            safetyCondition &= !lookupLiteral(node: symbol.lit)
        }
    }
    
    public func combine(implementation: Aiger) -> UnsafeMutablePointer<aiger>? {
        let combined_ = aiger_init()
        guard let combined = combined_ else {
            return nil
        }
        var implementationVars = 0
        
        // inputs
        for symbol in representation.inputs {
            let name: String = String(cString: symbol.name)
            if !name.hasPrefix("controllable_") {
                aiger_add_input(combined, symbol.lit, symbol.name)
            }
        }
        
        // latches
        for symbol in representation.latches {
            aiger_add_latch(combined, symbol.lit, symbol.next, symbol.name)
        }
        
        // outputs
        for symbol in representation.outputs {
            aiger_add_output(combined, symbol.lit, symbol.name)
        }
        
        // ands
        for and in representation.ands {
            aiger_add_and(combined, and.lhs, and.rhs0, and.rhs1)
        }
        
        // import implementation
        let offset = (representation.maxVar + 1) * 2
        func translateLit(_ implementation: Aiger, offset: UInt32, lit: UInt32) -> UInt32 {
            let (negated, normalizedLit) = aiger_normalize(lit)
            switch implementation.tag(forLit: normalizedLit) {
            case .Constant:
                // constant
                assert(normalizedLit == 0)
                return lit
            case .Input(let symbol):
                let translatedLit = UInt32(String(cString: symbol.name))!
                return negated ? aiger_not(translatedLit) : translatedLit
            case .And(_):
                // and gate
                return lit + offset
            default:
                assert(false)
                abort()
            }
        }
        
        for and in implementation.ands {
            let lhs = translateLit(implementation, offset: offset, lit: and.lhs)
            let rhs0 = translateLit(implementation, offset: offset, lit: and.rhs0)
            let rhs1 = translateLit(implementation, offset: offset, lit: and.rhs1)
            aiger_add_and(combined, lhs, rhs0, rhs1)
        }
        
        // define outputs as and gates
        for symbol in implementation.outputs {
            let origLit = UInt32(String(cString: symbol.name))!
            let funcLit = translateLit(implementation, offset: offset, lit: symbol.lit)
            aiger_add_and(combined, origLit, funcLit, 1)
        }
        
        return combined
    }
}
