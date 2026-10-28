import Foundation
import Testing
@testable import Mando

/// La casa configurable: guardar, migrar, editar sin perder el estado en vivo,
/// quitar, la entrada automática del receptor y la lista de apps del Apple TV.
@MainActor
@Suite(.serialized)
struct PruebasCasa {
    @Test func laConfiguracionSobreviveACerrarLaApp() throws {
        let almacen = almacenTemporal()
        var tele = Catalogo.nuevo(.lg, nombre: "Tele de la sala", cuarto: "Sala", host: "10.0.0.9")
        tele.estadoConocido = true
        tele.volumen = 42
        let casa = Casa(aparatos: [tele], almacen: almacen, fabrica: demo)
        casa.guardar()

        let otraVez = try #require(almacen.cargar())

        #expect(otraVez.aparatos.first?.nombre == "Tele de la sala")
        #expect(otraVez.aparatos.first?.host == "10.0.0.9")
        // El estado en vivo de ayer no se guarda.
        #expect(otraVez.aparatos.first?.volumen == 0)
        #expect(otraVez.aparatos.first?.estadoConocido == false)
        #expect(otraVez.ultimo == tele.id)
    }

    @Test func sinCasaGuardadaYSinLlavesEmpiezaVacia() {
        Credenciales.borrar("AppleTV")
        Llavero.borrar(ControladorLG.servicio, "LG")
        let casa = Casa.alAbrir(almacenTemporal())
        #expect(casa.aparatos.isEmpty)
        #expect(casa.actual == nil)
    }

    @Test func conLlavesDeLaVersionAnteriorArmaLaCasaAnterior() {
        Llavero.guardar(Data("llave".utf8), ControladorLG.servicio, "LG")
        defer { Llavero.borrar(ControladorLG.servicio, "LG") }

        let casa = Casa.alAbrir(almacenTemporal())

        // Con las mismas cuentas del Llavero, para no volver a emparejar.
        #expect(casa.aparatos.first { $0.tipo == .lg }?.llavero == "LG")
        #expect(casa.aparatos.first { $0.tipo == .appleTV }?.llavero == "AppleTV")
        #expect(casa.aparatos.first { $0.tipo == .googleTV }?.llavero == "Mando")
        let google = casa.aparatos.first { $0.tipo == .googleTV }
        #expect(google?.volumenEn == casa.aparatos.first { $0.tipo == .onkyo }?.id)
        #expect(google?.entradaAlElegir == "01")
    }

    @Test func editarNoPierdeElEstadoEnVivo() throws {
        let casa = Casa.deMuestra(onkyo: ControladorDemo(tipo: .onkyo), googleTV: ControladorDemo(tipo: .googleTV), appleTV: ControladorDemo(tipo: .appleTV), lg: ControladorDemo(tipo: .lg))
        let onkyo = try #require(casa.aparatos.first { $0.tipo == .onkyo })
        casa.mandar(.volumen(30), a: onkyo.id)

        var editado = try #require(casa[onkyo.id])
        editado.nombre = "Receptor"
        editado.entradas[0].visible = false
        casa.actualizar(editado)

        #expect(casa[onkyo.id]?.nombre == "Receptor")
        #expect(casa[onkyo.id]?.volumen == 30)
        #expect(casa[onkyo.id]?.entradasVisibles.contains { $0.clave == editado.entradas[0].clave } == false)
    }

    @Test func quitarUnReceptorSueltaALosQueLeMandabanVolumen() throws {
        let casa = Casa.deMuestra(onkyo: ControladorDemo(tipo: .onkyo), googleTV: ControladorDemo(tipo: .googleTV), appleTV: ControladorDemo(tipo: .appleTV), lg: ControladorDemo(tipo: .lg))
        let onkyo = try #require(casa.aparatos.first { $0.tipo == .onkyo }).id
        let google = try #require(casa.aparatos.first { $0.tipo == .googleTV }).id

        casa.quitar(onkyo)

        #expect(casa[onkyo] == nil)
        #expect(casa[google]?.volumenEn == nil)
        #expect(casa[google]?.entradaAlElegir == nil)
    }

    @Test func elegirElGoogleTVCambiaElOnkyoASuEntrada() async throws {
        let receptor = try ReceptorFalso()
        defer { receptor.apagar() }
        let puerto = try await receptor.arrancar()
        let casa = Casa.deMuestra(
            onkyo: ControladorOnkyo(host: "127.0.0.1", puerto: puerto, buscarSiFalla: false),
            googleTV: ControladorDemo(tipo: .googleTV), appleTV: ControladorDemo(tipo: .appleTV), lg: ControladorDemo(tipo: .lg)
        )
        let onkyo = try #require(casa.aparatos.first { $0.tipo == .onkyo }).id
        let google = try #require(casa.aparatos.first { $0.tipo == .googleTV }).id
        await casa.conectar(onkyo)
        // El receptor falso arranca en STRM BOX.
        try await esperar { casa[onkyo]?.entrada == "11" }

        casa.seleccionar(google)

        try await esperar { receptor.valor("SLI") == "01" }
    }

    @Test func traeLasAppsDelAppleTV() async throws {
        let tele = AppleTVFalso()
        defer { tele.apagar() }
        let puerto = try await tele.arrancar()
        Credenciales.borrar("PruebaAppleTV")
        let casa = Casa.deMuestra(
            onkyo: ControladorDemo(tipo: .onkyo), googleTV: ControladorDemo(tipo: .googleTV),
            appleTV: ControladorAppleTV(host: "127.0.0.1", puerto: puerto, cuenta: "PruebaAppleTV", buscarSiFalla: false),
            lg: ControladorDemo(tipo: .lg)
        )
        let apple = try #require(casa.aparatos.first { $0.tipo == .appleTV }).id
        _ = await casa.pedirCodigo(apple)
        _ = await casa.emparejar(apple, codigo: tele.pin)

        let apps = try #require(try await casa.appsInstaladas(apple))

        #expect(apps.map(\.nombre) == ["Infuse", "Plex"])
        #expect(apps.first?.id == "com.firecore.infuse")
    }

    @Test func laDireccionQueReportaElAparatoSeGuarda() async throws {
        let receptor = try ReceptorFalso()
        defer { receptor.apagar() }
        let puerto = try await receptor.arrancar()
        let almacen = almacenTemporal()
        let onkyo = Catalogo.nuevo(.onkyo, host: "127.0.0.1", puerto: nil)
        let casa = Casa(aparatos: [onkyo], almacen: almacen) { _ in
            ControladorOnkyo(host: "127.0.0.1", puerto: puerto, buscarSiFalla: false)
        }

        await casa.conectar(onkyo.id)

        try await esperar { almacen.cargar()?.aparatos.first?.puerto == puerto }
    }

    @Test func siAlgoSeReproduceEstaPrendido() async throws {
        let apple = ControladorQueReporta(reportes: [.appPorId("com.disney.disneyplus")])
        let casa = Casa.deMuestra(onkyo: ControladorDemo(tipo: .onkyo), googleTV: ControladorDemo(tipo: .googleTV), appleTV: apple, lg: ControladorDemo(tipo: .lg))
        let id = try #require(casa.aparatos.first { $0.tipo == .appleTV }).id

        await casa.conectar(id)
        try await esperar { casa[id]?.appAbierta != nil }
        // Una app abierta no dice si está prendido.
        #expect(casa[id]?.estadoConocido == false)

        apple.mandarReporte(.reproduciendo(Reproduciendo(titulo: "10 cosas que odio de ti")))
        try await esperar { casa[id]?.reproduciendo != nil }
        #expect(casa[id]?.encendido == true)
        #expect(casa[id]?.estadoConocido == true)
    }

    // MARK: - Ayudantes

    private func demo(_ a: Aparato) -> any Controlador { ControladorDemo(tipo: a.tipo) }

    private func almacenTemporal() -> Almacen {
        Almacen(archivo: URL.temporaryDirectory.appending(path: "casa-\(UUID().uuidString).json"))
    }

    private func esperar(
        hasta limite: Duration = .seconds(3),
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

/// Un controlador que reporta lo que la prueba le diga.
nonisolated final class ControladorQueReporta: Controlador, @unchecked Sendable {
    let reportes: AsyncStream<Reporte>
    private let avisar: AsyncStream<Reporte>.Continuation
    private let alConectar: [Reporte]

    init(reportes: [Reporte]) {
        alConectar = reportes
        (self.reportes, avisar) = AsyncStream.makeStream()
    }

    func conectar() async throws { alConectar.forEach { avisar.yield($0) } }
    func mandar(_ orden: Orden) async throws {}
    func mandarReporte(_ r: Reporte) { avisar.yield(r) }
}
