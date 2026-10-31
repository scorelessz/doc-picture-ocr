// 引擎输出的数据契约，与 Python 书籍线的 work/<名>.{vision,rapidocr}.json 字段一一对应
// （见 src/book_engines.py 顶部注释）。只加字段、不改字段，新旧实现才能逐字对拍。
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

    enum CodingKeys: String, CodingKey {
        case page, width, height, zoom, rotation, image, lines
        case pdfWidth = "pdf_width", pdfHeight = "pdf_height", nativeText = "native_text"
    }

    public init(page: Int, width: Int, height: Int, pdfWidth: Double, pdfHeight: Double,
                zoom: Double, rotation: Int = 0, image: String? = nil, nativeText: Bool = false,
                lines: [Line] = []) {
        self.page = page; self.width = width; self.height = height
        self.pdfWidth = pdfWidth; self.pdfHeight = pdfHeight
        self.zoom = zoom; self.rotation = rotation; self.image = image
        self.nativeText = nativeText; self.lines = lines
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
