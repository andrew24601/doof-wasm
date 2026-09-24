import { Assert } from "std/assert"
import { MinusClass, MinusField } from "./minus-ir"
import { classFieldOffset, classSize, fieldWidth } from "./minus-layout"

export function testPackedClassLayout(): none {
    class_ := MinusClass { name: "Packed", fields: [
        MinusField { name: "byte", typeName: "byte" },
        MinusField { name: "integer", typeName: "int" },
        MinusField { name: "flag", typeName: "bool" },
        MinusField { name: "short", typeName: "short" },
        MinusField { name: "double", typeName: "double" },
        MinusField { name: "long", typeName: "long" },
        MinusField { name: "unit", typeName: "none" },
        MinusField { name: "boxed", typeName: "any" },
        MinusField { name: "character", typeName: "char" },
    ] }
    offsets: int[] := [8, 12, 16, 18, 24, 32, 40, 40, 44]
    for index of 0..<offsets.length { Assert.equal(classFieldOffset(class_, index), offsets[index]) }
    Assert.equal(classSize(class_), 56)
    Assert.equal(fieldWidth("byte"), 1)
    Assert.equal(fieldWidth("short"), 2)
    Assert.equal(fieldWidth("any"), 4)
    Assert.equal(fieldWidth("double"), 8)
    Assert.equal(fieldWidth("none"), 0)
}

export function testSmallClassSize(): none {
    empty := MinusClass { name: "Empty" }
    oneByte := MinusClass { name: "OneByte", fields: [MinusField { name: "value", typeName: "byte" }] }
    Assert.equal(classSize(empty), 24)
    Assert.equal(classSize(oneByte), 24)
}

export function testClassSizesFollowReusableBlockClasses(): none {
    threeLongs := MinusClass { name: "ThreeLongs", fields: [
        MinusField { name: "a", typeName: "long" },
        MinusField { name: "b", typeName: "long" },
        MinusField { name: "c", typeName: "long" },
    ] }
    fourLongs := MinusClass { name: "FourLongs", fields: [
        MinusField { name: "a", typeName: "long" },
        MinusField { name: "b", typeName: "long" },
        MinusField { name: "c", typeName: "long" },
        MinusField { name: "d", typeName: "long" },
    ] }
    Assert.equal(classSize(threeLongs), 40)
    Assert.equal(classSize(fourLongs), 40)
}
