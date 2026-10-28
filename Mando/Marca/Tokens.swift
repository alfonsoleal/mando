import SwiftUI

// Tema Carbón: fondo casi negro, tarjetas planas y texto hueso.
extension Color {
    static let carbon = Color(hex: 0x121214)
    static let panel = Color(hex: 0x191919)
    /// Tecla presionada: un escalón arriba del panel, sin sombra.
    static let panelActivo = Color(hex: 0x232325)
    static let hilo = Color(hex: 0x262626)
    static let hueso = Color(hex: 0xF1EEE8)
    /// Texto secundario. 6.4:1 sobre el panel; el gris de la marca (#8A8A8A)
    /// queda en 5:1 y se pierde con el grano, por eso va un punto más claro.
    static let grisTexto = Color(hex: 0x9C9A96)
    /// Sólo para trazos decorativos (retícula, reglas). Nunca para texto.
    static let grisTrazo = Color(hex: 0x4A4A4C)
    static let verde = Color(hex: 0x00D749)
    /// Aviso de conexión: ámbar convencional, siempre con ícono y texto.
    static let ambar = Color(hex: 0xF2B544)

    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

enum Espacio {
    static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16
    static let xl: CGFloat = 24, xxl: CGFloat = 32, seccion: CGFloat = 48
}

enum Radio {
    static let tecla: CGFloat = 16
    static let tarjeta: CGFloat = 24
    static let chip: CGFloat = 999
}

enum Tipo {
    // Todas escalan con Dynamic Type a partir del estilo de sistema más parecido.
    static let titulo = Font.custom("Geist-Light", size: 34, relativeTo: .largeTitle)
    /// La palabra acento del título: Instrument Serif itálica, siempre en verde
    /// y un escalón arriba para igualar la altura de Geist.
    static let acento = Font.custom("InstrumentSerif-Italic", size: 38, relativeTo: .largeTitle)
    static let cuerpo = Font.custom("Geist-Regular", size: 17, relativeTo: .body)
    static let tecla = Font.custom("Geist-Medium", size: 15, relativeTo: .subheadline)
    /// Kickers, estados y todo lo que se mide (volumen, entradas).
    static let etiqueta = Font.custom("GeistMono-Regular", size: 12, relativeTo: .caption)
    static let dato = Font.custom("GeistMono-Regular", size: 17, relativeTo: .body)
    static let cifra = Font.custom("GeistMono-Regular", size: 88, relativeTo: .largeTitle)
}

enum Proporcion {
    /// La superficie del Apple TV y la cruceta del Google TV comparten
    /// proporción: un poco más ancha que alta para que el volumen y las apps
    /// quepan sin desplazar en un iPhone de tamaño normal.
    static let superficie: CGFloat = 1.18
}
