import { Assert } from "std/assert"
import { SourceNameCache, qualifiedName } from "./doof-lowering-support"
import { MinusModule, MinusClass, MinusInterface, MinusEnum, MinusFunction, MinusImport, minusModuleLookup, lookupMinusName } from "./minus-ir"

export function testQualifiedNamesSharePrefixesWithoutChangingSpelling(): none {
    cache := SourceNameCache {}
    for path of ["", "/a_b.do", "/a/b.do", "/compiler/src/long-module-name.do",
        "/a/this-is-a-long-shared-suffix.do", "/b/this-is-a-long-shared-suffix.do"] {
        for name of ["First", "Second", "_closure_123", "First"] {
            Assert.equal(qualifiedName(path, name, cache), qualifiedName(path, name))
        }
    }
    Assert.equal(cache.prefixes.length, 6)
    Assert.notEqual(qualifiedName("/a_b.do", "First", cache), qualifiedName("/a/b.do", "First", cache))
    Assert.notEqual(qualifiedName("/a/this-is-a-long-shared-suffix.do", "First", cache), qualifiedName("/b/this-is-a-long-shared-suffix.do", "First", cache))
    other := SourceNameCache {}
    Assert.equal(qualifiedName("/other.do", "Value", other), qualifiedName("/other.do", "Value"))
    Assert.equal(other.prefixes.length, 1)
    Assert.equal(cache.prefixes.length, 6)
}

export function testDeclarationLookupsRefreshForEveryDeclarationList(): none {
    module_ := MinusModule {}
    _ := minusModuleLookup(module_)
    module_.classes.push(MinusClass { name: "Class" })
    Assert.equal(lookupMinusName(minusModuleLookup(module_).classes, "Class"), 0)
    module_.interfaces.push(MinusInterface { name: "Interface" })
    Assert.equal(lookupMinusName(minusModuleLookup(module_).interfaces, "Interface"), 0)
    module_.enums.push(MinusEnum { name: "Enum" })
    Assert.equal(lookupMinusName(minusModuleLookup(module_).enums, "Enum"), 0)
    module_.functions.push(MinusFunction { name: "Function", result: "none" })
    Assert.equal(lookupMinusName(minusModuleLookup(module_).functions, "Function"), 0)
    module_.imports.push(MinusImport { name: "Import", importModule: "host", importName: "import", result: "none" })
    Assert.equal(lookupMinusName(minusModuleLookup(module_).imports, "Import"), 0)
    _ := module_.classes.pop()!
    Assert.equal(lookupMinusName(minusModuleLookup(module_).classes, "Class"), -1)
    Assert.equal(lookupMinusName(minusModuleLookup(module_).imports, "Import"), 0)
}
