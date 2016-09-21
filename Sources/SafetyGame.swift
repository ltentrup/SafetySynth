import CAiger
import CAigerHelper
import Aiger

typealias AigerLit = UInt32

struct SafetyGame {
    let representation: Aiger
    let controllableLits: [AigerLit]
    let uncontrollableLits: [AigerLit]
    let latchLits: [AigerLit]
    
    init(from: Aiger) {
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
        
        self.controllableLits = controllableLits
        self.uncontrollableLits = uncontrollableLits
        
        self.latchLits = from.latches.map({ $0.lit })
    }
    
    func combine(implementation: Aiger) -> UnsafeMutablePointer<aiger>? {
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
