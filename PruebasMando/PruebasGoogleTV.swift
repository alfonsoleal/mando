import Foundation
import Testing
@testable import Mando

/// De punta a punta: la casa contra un Google TV falso con TLS de verdad,
/// certificados de verdad y el código de emparejamiento calculado como la tele.
@MainActor
@Suite(.serialized)
struct PruebasGoogleTV {
    @Test func sinEmparejarPideEmparejar() async throws {
        let (casa, tele, google) = try await armar()
        defer { tele.apagar() }

        await casa.conectar(google)

        #expect(casa[google]?.conexion == .porEmparejar)
    }

    @Test func emparejaConElCodigoDeLaPantallaYLeeElEstado() async throws {
        let (casa, tele, google) = try await armar()
        defer { tele.apagar() }

        try await emparejar(casa, tele, google)

        #expect(casa[google]?.conexion == .conectado)
        try await esperar { casa[google]?.encendido == true && casa[google]?.appAbierta == "YouTube" }
        // 25 de 100 en la tele es 20 en la escala de 0 a 80 de la app.
        #expect(casa[google]?.volumen == 20)
        #expect(tele.configuradoPor == "iPhone")
    }

    @Test func unCodigoEquivocadoLoRechazaLaTele() async throws {
        let (casa, tele, google) = try await armar()
        defer { tele.apagar() }
        #expect(await casa.pedirCodigo(google) == nil)
        let bueno = try #require(tele.codigoEnPantalla)
        // Mismo dígito verificador, otro resto: la app no lo puede detectar
        // sola y tiene que preguntarle a la tele.
        let malo = String(bueno.prefix(2)) + (bueno.hasSuffix("0000") ? "0001" : "0000")

        let error = await casa.emparejar(google, codigo: malo)

        #expect(error?.contains("no coincide") == true)
        #expect(casa[google]?.conexion != .conectado)
    }

    @Test func unCodigoConDigitoVerificadorMaloNiSeManda() async throws {
        let (casa, tele, google) = try await armar()
        defer { tele.apagar() }
        #expect(await casa.pedirCodigo(google) == nil)
        let bueno = try #require(tele.codigoEnPantalla)
        let primero = UInt8(bueno.prefix(2), radix: 16)!
        let malo = String(format: "%02X", primero ^ 0xFF) + bueno.dropFirst(2)

        #expect(await casa.emparejar(google, codigo: malo)?.contains("no coincide") == true)
        // La tele sigue mostrando el mismo código: el bueno todavía sirve.
        #expect(await casa.emparejar(google, codigo: bueno) == nil)
    }

    @Test func lasTeclasYLasAppsLleganALaTele() async throws {
        let (casa, tele, google) = try await armar()
        defer { tele.apagar() }
        try await emparejar(casa, tele, google)

        casa.mandar(.mover(.arriba), a: google)
        casa.mandar(.elegir, a: google)
        casa.mandar(.atras, a: google)
        casa.mandar(.abrirApp(Aplicacion(id: "https://www.netflix.com/title", nombre: "Netflix")), a: google)

        try await esperar { tele.teclas == [19, 23, 4] && tele.enlaces == ["https://www.netflix.com/title"] }
    }

    @Test func contestaElPingParaQueLaTeleNoCorte() async throws {
        let (casa, tele, google) = try await armar()
        defer { tele.apagar() }
        try await emparejar(casa, tele, google)

        try await esperar { tele.pongs == [7] }
    }

    @Test func prenderLaTeleYaPrendidaNoLaApaga() async throws {
        let (casa, tele, google) = try await armar()
        defer { tele.apagar() }
        try await emparejar(casa, tele, google)
        try await esperar { casa[google]?.encendido == true }

        casa.mandar(.encender(true), a: google)
        casa.mandar(.atras, a: google)

        // Sólo «atrás»: la tecla de encendido de Android alterna, y la tele
        // ya estaba prendida.
        try await esperar { tele.teclas == [4] }
    }

    @Test func sinAvisoDeCampoTecleaYSoloMandaLaDiferencia() async throws {
        let (casa, tele, google) = try await armar()
        defer { tele.apagar() }
        try await emparejar(casa, tele, google)
        try await esperar { tele.pongs == [7] }

        #expect(await casa.escribir("Sev", en: google) == nil)
        try await esperar { tele.teclas == [47, 33, 50] }
        // Borrar una letra en el teléfono manda una sola tecla de borrar.
        #expect(await casa.escribir("Se", en: google) == nil)

        try await esperar { tele.teclas == [47, 33, 50, 67] }
        #expect(tele.escrito.isEmpty)
    }

    @Test func elTecladoDelControlNoTieneAcentos() {
        #expect(AndroidTV.paraTeclas("Canción Ñandú 2!") == "cancion nandu 2")
    }

    @Test func escribeEnLaBusquedaConLosContadoresDeLaTele() async throws {
        let (casa, tele, google) = try await armar()
        defer { tele.apagar() }
        try await emparejar(casa, tele, google)
        try await esperar { tele.pongs == [7] }

        tele.abrirBusqueda(ime: 3, campo: 9)
        try await Task.sleep(for: .milliseconds(100))
        let primero = await casa.escribir("Sev", en: google)
        let segundo = await casa.escribir("Severance", en: google)

        #expect(primero == nil && segundo == nil)
        try await esperar { tele.escrito.count == 2 }
        // El texto completo cada vez, con los contadores que mandó la tele.
        #expect(tele.escrito.map(\.texto) == ["Sev", "Severance"])
        #expect(tele.escrito.allSatisfy { $0.ime == 3 && $0.campo == 9 })
    }

    @Test func elVolumenDelGoogleTVLoLlevaElOnkyo() throws {
        let casa = Casa.deMuestra(onkyo: ControladorDemo(tipo: .onkyo), googleTV: ControladorDemo(tipo: .googleTV), appleTV: ControladorDemo(tipo: .appleTV), lg: ControladorDemo(tipo: .lg))
        let google = try #require(casa.aparatos.first { $0.tipo == .googleTV })
        let onkyo = try #require(casa.aparatos.first { $0.tipo == .onkyo })
        #expect(casa.destinoDe(.subirVolumen, desde: google.id) == onkyo.id)
        #expect(casa.destinoDe(.mover(.arriba), desde: google.id) == google.id)
    }

    @Test func protobufIdaYVuelta() {
        var m = Protobuf()
        m.entero(1, 300)
        m.texto(2, "Mañana")
        m.mensaje(3) { $0.booleano(1, true) }
        let c = Protobuf.campos(m.datos)
        #expect(c[1]?.entero == 300)
        #expect(c[2]?.bytes == Data("Mañana".utf8))
        #expect(Protobuf.campos(c[3]!.bytes!)[1]?.entero == 1)

        var bufer = Marco.envolver(m.datos) + Marco.envolver(Data([1, 2]))
        bufer.append(contentsOf: [5, 9]) // un mensaje a medias
        #expect(Marco.extraer(de: &bufer).count == 2)
        #expect(bufer == Data([5, 9]))
    }

    // MARK: - Ayudantes

    private func armar() async throws -> (Casa, GoogleTVFalso, Aparato.ID) {
        let tele = try GoogleTVFalso()
        let puertos = try await tele.arrancar()
        // Un certificado nuevo por prueba: cada tele falsa empieza sin conocerlo.
        Certificado.borrar(nombre: "PruebaMando")
        let control = ControladorGoogleTV(
            host: "127.0.0.1",
            puertoControl: puertos.control,
            puertoEmparejar: puertos.emparejar,
            nombreCertificado: "PruebaMando",
            buscarSiFalla: false
        )
        let casa = Casa.deMuestra(onkyo: ControladorDemo(tipo: .onkyo), googleTV: control, appleTV: ControladorDemo(tipo: .appleTV), lg: ControladorDemo(tipo: .lg))
        let google = try #require(casa.aparatos.first { $0.tipo == .googleTV }).id
        return (casa, tele, google)
    }

    private func emparejar(_ casa: Casa, _ tele: GoogleTVFalso, _ google: Aparato.ID) async throws {
        let errorAlPedir = await casa.pedirCodigo(google)
        #expect(errorAlPedir == nil)
        let codigo = try #require(tele.codigoEnPantalla)
        let errorAlEmparejar = await casa.emparejar(google, codigo: codigo.lowercased())
        #expect(errorAlEmparejar == nil)
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
