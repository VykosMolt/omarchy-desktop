-- Define terminal tag so themes and bindings can single terminals out. This
-- desktop ships kitty; TUIs and its own terminal windows launch under
-- dedicated app-ids (org.omarchy.terminal, TUI.float, ...),
-- so match those too. The class is matched in full.
o.window("(kitty|org\\.omarchy\\..*|TUI\\..*)", { tag = "+terminal" })
