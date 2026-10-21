"""书籍线 OCR 的桌面界面(Tkinter)。

    app/paths.py      resource_path() —— 开发态/打包态统一的资源定位
    app/settings.py   参数持久化(~/Library/Application Support/)
    app/pipeline.py   Job / Runner —— 工作线程 + 事件队列, 不碰 Tk
    app/gui.py        界面
    app/main.py       入口, 另带 --selftest 无界面模式

流水线本身仍是 src/book_*.py + src/run_books.py, 这里一行识别逻辑都没有。
"""

__all__ = ["paths", "settings", "pipeline"]
