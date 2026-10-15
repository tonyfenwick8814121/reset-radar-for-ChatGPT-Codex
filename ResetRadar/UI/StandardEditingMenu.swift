import AppKit

enum StandardEditingMenu {
    static func make(locale: AppLocale) -> NSMenu {
        let main = NSMenu()
        let app = NSMenuItem()
        app.submenu = NSMenu(title: "Reset Radar")
        main.addItem(app)
        let edit = NSMenu(title: locale == .zhHans ? "编辑" : "Edit")
        for (zh, en, action, key) in [
            ("撤销", "Undo", "undo:", "z"), ("重做", "Redo", "redo:", "Z"),
            ("剪切", "Cut", "cut:", "x"), ("复制", "Copy", "copy:", "c"),
            ("粘贴", "Paste", "paste:", "v"), ("全选", "Select All", "selectAll:", "a")
        ] {
            // A nil target routes standard shortcuts to the focused field's responder chain.
            edit.addItem(withTitle: locale == .zhHans ? zh : en, action: Selector(action), keyEquivalent: key)
        }
        let item = NSMenuItem(title: edit.title, action: nil, keyEquivalent: "")
        item.submenu = edit
        main.addItem(item)
        return main
    }
}
