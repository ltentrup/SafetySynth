import CAiger
import Aiger
import CUDD
import SafetyGameSolver

import Foundation

func printArguments(name: String) {
    print("\(name) [--synthesize] instance")
}

var arguments = CommandLine.arguments
arguments.remove(at: 0)
var specificationFile: String? = nil
var synthesize = false
var reorderingAlgorithm: CUDDReordering = .GroupSift

for argument in arguments {
    if argument == "--synthesize" {
        synthesize = true
    } else if argument == "--alt" {
        reorderingAlgorithm = .LazySift
    } else {
        specificationFile = argument
        break
    }
}

guard let specificationFile = specificationFile else {
    print("error: no instance given")
    printArguments(name: CommandLine.arguments[0])
    exit(1)
}

guard let specificationPointer = aiger_init() else {
    exit(1)
}
let result = aiger_open_and_read_from_file(specificationPointer, specificationFile)
if result != nil {
    print("cannot read aiger file \(specificationFile)")
    exit(1)
}

let safetyGame = SafetyGame(from: Aiger(from: specificationPointer))
let solver = SafetyGameSolver(instance: safetyGame)

guard let solution = solver.solve() else {
    print("unrealizable")
    exit(0)
}
//print("Size of winning region is \(solution.dagSize())")
if !synthesize {
    print("realizable")
    exit(0)
}

let rawStrategy = solver.synthesize(winningRegion: solution)
guard let minimizedStrategy = minimizeWithABC(rawStrategy) else {
    print("minimizing strategy failed")
    exit(1)
}

let combined = safetyGame.combine(implementation: Aiger(from: minimizedStrategy))
aiger_add_comment(combined, "realizable")
aiger_write_to_file(combined, aiger_ascii_mode, stdout)

solver.printWinningRegion(winningRegion: solution)

