/// Observes rendered terminal content, independently of a network connection.
/// Embedders must copy cells in these callbacks: BufferLine storage is recycled.
public protocol TerminalContentObserver: AnyObject {
    func terminal(_ terminal: Terminal, willScrollOut line: BufferLine)
    func terminalWillDiscardScreen(_ terminal: Terminal)
    func terminalDidUpdate(_ terminal: Terminal)
    func terminalDidResize(_ terminal: Terminal)
}
