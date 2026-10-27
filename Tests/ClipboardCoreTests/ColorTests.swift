import Foundation
import Testing
import ClipboardCore
@testable import ClipShelf

struct ColorTests {
    @Test func recognizesStandaloneSixDigitColors() {
        for value in ["#000000", "#FFFFFF", "ff8800", "12AB34", "  #aBcDeF\n"] {
            #expect(textClipKind(value) == .color)
        }
        #expect(hexColorValue("#12AB34") == 0x12AB34)
        for value in ["123456", "#FFF", "#12345678", "rgb(1, 2, 3)", "red", "color: #FF0000", "#GG0000", "ＦＦ００００", "#12 3456"] {
            #expect(textClipKind(value) == .text)
        }
        #expect(textClipKind("https://example.com") == .link)
    }

    @Test func colorPersistsAndEditsBackToText() throws {
        let text = "#FF8800"
        let clip = Clip(kind: textClipKind(text), text: text, sourceName: "Test", sourceBundle: "test",
                        items: [[Representation(type: "public.utf8-plain-text", data: Data(text.utf8))]], identity: Data(text.utf8))
        let restored = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(clip))
        #expect(restored == clip)
        var history = History(clips: [restored])
        try history.editText(id: clip.id, text: "ordinary text")
        #expect(history.clips.first?.kind == .text)
        #expect(history.clips.first?.text == "ordinary text")
    }
    @Test func previewFormatsColorSpacesAndChoosesReadableText() {
        let red = ClipColor(value: 0xFF0000)
        #expect(red.hex == "#FF0000")
        #expect(red.codes == ["rgb(255, 0, 0)", "hsl(0, 100%, 50%)", "hsb(0, 100%, 100%)"])
        #expect(ClipColor(value: 0).codes == ["rgb(0, 0, 0)", "hsl(0, 0%, 0%)", "hsb(0, 0%, 0%)"])
        #expect(ClipColor(value: 0xFFFFFF).codes == ["rgb(255, 255, 255)", "hsl(0, 0%, 100%)", "hsb(0, 0%, 100%)"])
        #expect(ClipColor(value: 0xEA4336).usesLightText)
        #expect(ClipColor(value: 0).usesLightText)
        #expect(!ClipColor(value: 0xFFFFFF).usesLightText)
    }

}
