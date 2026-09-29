// Transient source/runtime construction boundary. Only the structured body is
// retained; the input blocks and derived graph are discarded after building.
import { MinusBlock, MinusFunction, MinusValue } from "./minus-ir"
import { structureMinusBlocks } from "./minus-control-flow"

export function createMinusFunction(name: string, params: MinusValue[] = [], result: string = "none", exported: bool = false, blocks: MinusBlock[] = [], line: int = 0, sourcePath: string = "", exportName: string = "", capturePanics: bool = false): MinusFunction {
    body := structureMinusBlocks(blocks) else { panic("lowering produced irreducible control flow in " + name) }
    return MinusFunction { name, params, result, exported, body, line, sourcePath, exportName, capturePanics }
}
