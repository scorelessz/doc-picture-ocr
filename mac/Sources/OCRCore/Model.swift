// 引擎输出的数据契约，与 Python 书籍线的 work/<名>.{vision,rapidocr}.json 字段一一对应
// （见 python-final:src/book_engines.py 顶部注释）。只加字段、不改字段，新旧实现才能逐字对拍。
//
// 坐标：像素，原点左上，像素 = 视觉 PDF 点 × zoom。

public struct Line: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    public var conf: Double
    public var text: String

    public init(x: Double, y: Double, w: Double, h: Double, conf: Double, text: String) {
        self.x = x; self.y = y; self.w = w; self.h = h; self.conf = conf; self.text = text
    }
}

public struct PageDoc: Codable, Equatable, Sendable {
    public var page: Int
    public var width: Int
    public var height: Int
    public var pdfWidth: Double
    public var pdfHeight: Double
    public var zoom: Double
    public var rotation: Int
    public var image: String?
    public var nativeText: Bool
    public var lines: [Line]
    /// 渲染图没有墨迹。只在闸门命中时写，Python 产物没有这个键。
    public var noInk: Bool?
    /// lines 的来源。闸门命中且有原生文字层时是 "native_text"，不是识别结果。
    public var textSource: String?
    /// 这页判定为倒置/横置，已顺时针转这么多度再识别；坐标仍是原页的。只在非 0 时写。
    public var pageRotation: Int?

    enum CodingKeys: String, CodingKey {
        case page, width, height, zoom, rotation, image, lines
        case pdfWidth = "pdf_width", pdfHeight = "pdf_height", nativeText = "native_text"
        case noInk = "no_ink", textSource = "text_source", pageRotation = "page_rotation"
    }

    public init(page: Int, width: Int, height: Int, pdfWidth: Double, pdfHeight: Double,
                zoom: Double, rotation: Int = 0, image: String? = nil, nativeText: Bool = false,
                lines: [Line] = [], noInk: Bool? = nil, textSource: String? = nil) {
        self.page = page; self.width = width; self.height = height
        self.pdfWidth = pdfWidth; self.pdfHeight = pdfHeight
        self.zoom = zoom; self.rotation = rotation; self.image = image
        self.nativeText = nativeText; self.lines = lines
        self.noInk = noInk; self.textSource = textSource
    }
}

public struct EngineDoc: Codable, Equatable, Sendable {
    public var source: String
    public var engine: String
    public var dpi: Double
    public var pages: [PageDoc]

    public init(source: String, engine: String, dpi: Double, pages: [PageDoc] = []) {
        self.source = source; self.engine = engine; self.dpi = dpi; self.pages = pages
    }
}
