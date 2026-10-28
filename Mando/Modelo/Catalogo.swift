import Foundation

/// Con qué llega cada tipo de aparato al agregarlo. Todo se puede renombrar,
/// ocultar y reordenar después en su configuración.
enum Catalogo {
    static func nuevo(_ tipo: TipoAparato, nombre: String? = nil, cuarto: String = "", host: String? = nil, puerto: UInt16? = nil) -> Aparato {
        Aparato(
            nombre: nombre ?? tipo.nombre, cuarto: cuarto, tipo: tipo, host: host, puerto: puerto,
            apps: apps(tipo), entradas: tipo == .onkyo ? entradasOnkyo : [], modos: tipo == .onkyo ? modosOnkyo : []
        )
    }

    static func apps(_ tipo: TipoAparato) -> [Aplicacion] {
        switch tipo {
        case .appleTV:
            [
                Aplicacion(id: "com.firecore.infuse", nombre: "Infuse"),
                Aplicacion(id: "com.apple.TVWatchList", nombre: "Apple TV"),
                Aplicacion(id: "com.netflix.Netflix", nombre: "Netflix"),
                Aplicacion(id: "com.google.ios.youtube", nombre: "YouTube"),
                Aplicacion(id: "com.wbd.stream", nombre: "Max"),
                Aplicacion(id: "com.apple.TVMusic", nombre: "Música"),
            ]
        case .googleTV:
            AndroidTV.enlaces.map { Aplicacion(id: $0.value, nombre: $0.key) }.sorted { $0.nombre < $1.nombre }
        case .onkyo, .lg:
            []
        }
    }

    /// Las entradas de eISCP con el nombre que traen impreso los Onkyo con
    /// red (TX-NR838 y parecidos). Las que un modelo no tiene se ocultan.
    static let entradasOnkyo = [
        Entrada(clave: "01", etiqueta: "CBL/SAT", nombre: "Cable"),
        Entrada(clave: "11", etiqueta: "STRM BOX", nombre: "Streaming"),
        Entrada(clave: "10", etiqueta: "BD/DVD", nombre: "Blu-ray"),
        Entrada(clave: "02", etiqueta: "GAME", nombre: "Consola"),
        Entrada(clave: "05", etiqueta: "PC", nombre: "Computadora"),
        Entrada(clave: "03", etiqueta: "AUX", nombre: "Auxiliar"),
        Entrada(clave: "12", etiqueta: "TV", nombre: "Tele"),
        Entrada(clave: "23", etiqueta: "CD", nombre: "CD"),
        Entrada(clave: "22", etiqueta: "PHONO", nombre: "Tocadiscos"),
        Entrada(clave: "24", etiqueta: "TUNER", nombre: "Radio"),
        Entrada(clave: "2E", etiqueta: "BLUETOOTH", nombre: "Bluetooth"),
        Entrada(clave: "2B", etiqueta: "NET", nombre: "Red"),
    ]

    static let modosOnkyo = [
        Modo(clave: "01", nombre: "Direct"),
        Modo(clave: "11", nombre: "Pure Audio"),
        Modo(clave: "00", nombre: "Estéreo"),
        Modo(clave: "0C", nombre: "Todo estéreo"),
        Modo(clave: "40", nombre: "Straight Decode"),
    ]

    /// La casa tal como estaba escrita antes de que la app se
    /// pudiera configurar. Se usa una sola vez, para no perder sus
    /// emparejamientos al actualizar (las llaves viven en las cuentas
    /// «AppleTV» y «LG» del Llavero).
    static func casaAnterior() -> [Aparato] {
        var onkyo = nuevo(.onkyo, cuarto: "Estudio")
        onkyo.entradas = onkyo.entradas.map { e in
            var e = e
            if e.clave == "01" { e.nombre = "Google TV" }
            e.visible = ["01", "11", "10", "02", "12", "2E", "2B", "22"].contains(e.clave)
            return e
        }
        let lg = Aparato(nombre: "Tele LG", cuarto: "Sala", tipo: .lg, llavero: "LG")
        var appleTV = nuevo(.appleTV, cuarto: "Sala")
        appleTV.llavero = "AppleTV"
        appleTV.volumenEn = lg.id
        var googleTV = nuevo(.googleTV, cuarto: "Estudio")
        // El certificado con que ya está emparejado se llama «Mando».
        googleTV.llavero = "Mando"
        googleTV.volumenEn = onkyo.id
        googleTV.entradaAlElegir = "01"
        return [appleTV, lg, googleTV, onkyo]
    }
}
