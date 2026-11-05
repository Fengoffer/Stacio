# SwiftTerm upstream

This source is vendored from `https://github.com/migueldeicaza/SwiftTerm.git`
at commit `87a7888edc0ae415922174e4e6c0486f3991e0ea`.

Stacio's local change exposes a public read-only `BufferLine.isWrapped` accessor
so the terminal gutter can distinguish logical lines from soft-wrapped
continuation rows without runtime reflection. SwiftTerm retains write access.
