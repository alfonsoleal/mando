import Foundation
import Testing
@testable import Mando

/// De punta a punta: la casa contra un Apple TV falso que habla Companion
/// con SRP, firmas Ed25519 y canal cifrado de verdad.
@MainActor
@Suite(.serialized)
struct PruebasAppleTV {
    @Test func sinEmparejarPideEmparejar() async throws {
        let (casa, tele, apple) = try await armar()
        defer { tele.apagar() }

        await casa.conectar(apple)

        #expect(casa[apple]?.conexion == .porEmparejar)
    }

    @Test func emparejaConElPinYAbreLaSesion() async throws {
        let (casa, tele, apple) = try await armar()
        defer { tele.apagar() }

        try await emparejar(casa, tele, apple)

        #expect(casa[apple]?.conexion == .conectado)
        try await esperar { casa[apple]?.encendido == true }
        // Sin presentarse y abrir la sesión de control, el Apple TV ignora las teclas.
        #expect(Array(tele.peticiones.prefix(2)) == ["_systemInfo", "_sessionStart"])
        #expect(tele.peticiones.contains("_interest"))
    }

    @Test func unPinEquivocadoNoGuardaNada() async throws {
        let (casa, tele, apple) = try await armar()
        defer { tele.apagar() }
        #expect(await casa.pedirCodigo(apple) == nil)

        let error = await casa.emparejar(apple, codigo: "9999")

        #expect(error?.contains("no coincide") == true)
        #expect(Credenciales.leer("PruebaAppleTV") == nil)
        #expect(casa[apple]?.conexion != .conectado)
    }

    @Test func lasTeclasYLasAppsLleganAlAppleTV() async throws {
        let (casa, tele, apple) = try await armar()
        defer { tele.apagar() }
        try await emparejar(casa, tele, apple)

        casa.mandar(.mover(.arriba), a: apple)
        try await esperar { tele.teclas == [1] }
        casa.mandar(.elegir, a: apple)
        try await esperar { tele.teclas == [1, 6] }
        casa.mandar(.abrirApp(Aplicacion(id: "com.firecore.infuse", nombre: "Infuse")), a: apple)

        try await esperar { tele.apps == ["com.firecore.infuse"] && casa[apple]?.appAbierta == "Infuse" }
    }

    @Test func laSiguienteVezConectaSinVolverAEmparejar() async throws {
        let tele = AppleTVFalso()
        defer { tele.apagar() }
        let puerto = try await tele.arrancar()
        Credenciales.borrar("PruebaAppleTV")
        let primera = casaCon(puerto)
        let apple1 = primera.aparatos.first { $0.tipo == .appleTV }!.id
        try await emparejar(primera, tele, apple1)

        // Como abrir la app otro día: otro controlador, mismas credenciales.
        let segunda = casaCon(puerto)
        let apple2 = segunda.aparatos.first { $0.tipo == .appleTV }!.id
        await segunda.conectar(apple2)

        #expect(segunda[apple2]?.conexion == .conectado)
    }

    @Test func siElAppleTVOlvidoAlTelefonoPideEmparejarOtraVez() async throws {
        let tele = AppleTVFalso()
        defer { tele.apagar() }
        let puerto = try await tele.arrancar()
        Credenciales.borrar("PruebaAppleTV")
        let primera = casaCon(puerto)
        let apple1 = primera.aparatos.first { $0.tipo == .appleTV }!.id
        try await emparejar(primera, tele, apple1)

        tele.olvidarEmparejamientos()
        let segunda = casaCon(puerto)
        let apple2 = segunda.aparatos.first { $0.tipo == .appleTV }!.id
        await segunda.conectar(apple2)

        #expect(segunda[apple2]?.conexion == .porEmparejar)
        #expect(Credenciales.leer("PruebaAppleTV") == nil)
    }

    @Test func escribeEnElCampoDelAppleTV() async throws {
        let (casa, tele, apple) = try await armar()
        defer { tele.apagar() }
        try await emparejar(casa, tele, apple)
        tele.campoAbierto = true

        #expect(await casa.escribir("Severance", en: apple) == nil)

        // Primero se vacía el campo y luego va el texto completo.
        try await esperar { tele.textos == ["", "Severance"] }
        #expect(tele.clasesDeTexto.isSuperset(of: ["RTITextOperations", "TIKeyboardOutput"]))
    }

    @Test func sinCampoActivoElAppleTVDiceQueHacer() async throws {
        let (casa, tele, apple) = try await armar()
        defer { tele.apagar() }
        try await emparejar(casa, tele, apple)

        let error = await casa.escribir("Severance", en: apple)

        #expect(error?.contains("abre la búsqueda") == true)
        #expect(tele.textos.isEmpty)
    }

    @Test func soloAceptaAnunciosDeAppleTV() {
        // Los anuncios reales de la casa: el Apple TV, una Mac y un iPad.
        #expect(ControladorAppleTV.esAppleTV(["rpMd": "AppleTV5,3", "rpVr": "715.2"]))
        #expect(!ControladorAppleTV.esAppleTV(["rpMd": "Macmini9,1"]))
        #expect(!ControladorAppleTV.esAppleTV(["rpMd": "iPad17,1"]))
        #expect(!ControladorAppleTV.esAppleTV([:]))
    }

    @Test func opackIdaYVuelta() throws {
        let largo = String(repeating: "á", count: 40)
        let muchos = OPACK.diccionario((0..<16).map { (.texto("k\($0)"), .entero(Int64($0) * 1000)) })
        let valor = OPACK.dic([
            "_i": .texto("_hidC"), "_x": .entero(70_000), "chico": .entero(7), "neg": .entero(-2),
            "largo": .texto(largo), "bytes": .datos(Data(0..<40)), "si": .booleano(true),
            "nada": .nulo, "lista": .lista([.entero(1), .texto("dos")]), "muchos": muchos,
            "real": .real(1.5),
        ])
        #expect(try OPACK.desempacar(valor.empacado) == valor)
    }

    @Test func opackLeeReferenciasARepetidos() throws {
        // {"a": "b", "a": "b"} con el segundo par escrito como referencias.
        let datos = Data([0xE2, 0x41, 0x61, 0x41, 0x62, 0xA0, 0xA1])
        let v = try OPACK.desempacar(datos)
        #expect(v == .diccionario([(.texto("a"), .texto("b")), (.texto("a"), .texto("b"))]))
    }

    @Test func tlv8ParteYJuntaValoresLargos() {
        let grande = Data((0..<600).map { UInt8($0 % 251) })
        let armado = TLV8.armar([(TLV8.estado, Data([3])), (TLV8.llavePublica, grande)])
        let leido = TLV8.leer(armado)
        #expect(leido[TLV8.llavePublica] == grande)
        #expect(leido[TLV8.estado] == Data([3]))
    }

    // MARK: - Ayudantes

    private func casaCon(_ puerto: UInt16) -> Casa {
        Casa.deMuestra(
            onkyo: ControladorDemo(tipo: .onkyo),
            googleTV: ControladorDemo(tipo: .googleTV),
            appleTV: ControladorAppleTV(host: "127.0.0.1", puerto: puerto, cuenta: "PruebaAppleTV", buscarSiFalla: false), lg: ControladorDemo(tipo: .lg)
        )
    }

    private func armar() async throws -> (Casa, AppleTVFalso, Aparato.ID) {
        let tele = AppleTVFalso()
        let puerto = try await tele.arrancar()
        Credenciales.borrar("PruebaAppleTV")
        let casa = casaCon(puerto)
        let apple = try #require(casa.aparatos.first { $0.tipo == .appleTV }).id
        return (casa, tele, apple)
    }

    private func emparejar(_ casa: Casa, _ tele: AppleTVFalso, _ apple: Aparato.ID) async throws {
        let alPedir = await casa.pedirCodigo(apple)
        #expect(alPedir == nil)
        let alEmparejar = await casa.emparejar(apple, codigo: tele.pin)
        #expect(alEmparejar == nil)
    }

    private func esperar(
        hasta limite: Duration = .seconds(5),
        _ condicion: () -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let fin = ContinuousClock.now + limite
        while ContinuousClock.now < fin {
            if condicion() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("No se cumplió a tiempo", sourceLocation: sourceLocation)
    }
}
