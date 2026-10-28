import CryptoKit
import Foundation
import Network
import Security
@testable import Mando

/// Un Google TV de mentira con los dos puertos de verdad: emparejamiento
/// (TLS, protocolo polo) y control (TLS, mensajes del control remoto). Exige
/// certificado de cliente y sólo obedece a los que emparejó, como la tele.
nonisolated final class GoogleTVFalso: @unchecked Sendable {
    private let candado = NSLock()
    private let cola = DispatchQueue(label: "google-tv-falso")
    private let identidad: SecIdentity
    private var oyentes: [NWListener] = []
    private var conexiones: [NWConnection] = []
    private var emparejados: Set<Data> = []
    private var secretoEsperado: Data?

    private(set) var codigoEnPantalla: String?
    private(set) var teclas: [Int] = []
    private(set) var enlaces: [String] = []
    private(set) var pongs: [UInt64] = []
    private(set) var configuradoPor: String?
    /// Lo escrito en el campo de búsqueda, con los contadores que traía.
    private(set) var escrito: [(texto: String, ime: UInt64, campo: UInt64)] = []
    private var controles: [NWConnection] = []

    /// Como cuando alguien abre la búsqueda: la tele muestra el teclado y
    /// manda el estado del campo con sus contadores.
    func abrirBusqueda(ime: Int, campo: Int) {
        let abiertas = candado.withLock { controles }
        for c in abiertas {
            mandar(c) { $0.mensaje(22) { s in s.mensaje(2) { t in t.entero(1, campo) } } }
            mandar(c) { $0.mensaje(21) { b in b.entero(1, ime); b.entero(2, campo) } }
        }
    }

    init() throws {
        identidad = try Certificado.identidad(nombre: "GoogleTVFalso")
    }

    func arrancar() async throws -> (control: UInt16, emparejar: UInt16) {
        let control = try await escuchar { [weak self] c, llave in self?.atenderControl(c, llave) }
        let emparejar = try await escuchar { [weak self] c, llave in self?.atenderEmparejar(c, llave) }
        return (control, emparejar)
    }

    func apagar() {
        candado.withLock {
            oyentes.forEach { $0.cancel() }
            conexiones.forEach { $0.cancel() }
        }
    }

    // MARK: - Red

    private func escuchar(_ atender: @escaping @Sendable (NWConnection, Caja<SecKey>) -> Void) async throws -> UInt16 {
        let llaveCliente = Caja<SecKey>()
        let tls = NWProtocolTLS.Options()
        let opciones = tls.securityProtocolOptions
        sec_protocol_options_set_local_identity(opciones, sec_identity_create(identidad)!)
        sec_protocol_options_set_peer_authentication_required(opciones, true)
        sec_protocol_options_set_verify_block(opciones, { _, confianza, listo in
            let trust = sec_trust_copy_ref(confianza).takeRetainedValue()
            if let cadena = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let c = cadena.first {
                llaveCliente.valor = SecCertificateCopyKey(c)
            }
            listo(true)
        }, cola)
        let oyente = try NWListener(using: NWParameters(tls: tls), on: .any)
        oyente.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            self.candado.withLock { self.conexiones.append(c) }
            c.stateUpdateHandler = { estado in
                if case .ready = estado { atender(c, llaveCliente) }
            }
            c.start(queue: self.cola)
        }
        candado.withLock { oyentes.append(oyente) }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let una = Unico()
            oyente.stateUpdateHandler = { estado in
                switch estado {
                case .ready: if una.primero() { c.resume() }
                case .failed(let e): if una.primero() { c.resume(throwing: e) }
                default: break
                }
            }
            oyente.start(queue: cola)
        }
        return oyente.port!.rawValue
    }

    private func leer(_ c: NWConnection, bufer: Data = Data(), _ cada: @escaping (Data) -> Void) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] datos, _, completo, error in
            guard let self, error == nil else { return }
            var bufer = bufer
            if let datos { bufer.append(datos) }
            Marco.extraer(de: &bufer).forEach(cada)
            if !completo { self.leer(c, bufer: bufer, cada) }
        }
    }

    private func mandar(_ c: NWConnection, _ armar: (inout Protobuf) -> Void) {
        var m = Protobuf()
        armar(&m)
        c.send(content: Marco.envolver(m.datos), completion: .idempotent)
    }

    // MARK: - Emparejamiento

    private func atenderEmparejar(_ c: NWConnection, _ llaveCliente: Caja<SecKey>) {
        leer(c) { [weak self] mensaje in
            guard let self else { return }
            let campos = Protobuf.campos(mensaje).numeros
            if campos.contains(10) {
                self.responder(c, estado: 200) { $0.mensaje(11) { a in a.texto(1, "Tele falsa") } }
            } else if campos.contains(20) {
                self.responder(c, estado: 200) { $0.mensaje(20) { o in
                    o.mensaje(1) { e in e.entero(1, 3); e.entero(2, 6) }
                    o.entero(3, 1)
                } }
            } else if campos.contains(30) {
                self.mostrarCodigo(para: llaveCliente.valor)
                self.responder(c, estado: 200) { $0.mensaje(31) { _ in } }
            } else if campos.contains(40) {
                let secreto = Protobuf.campos(mensaje)[40]?.bytes.flatMap { Protobuf.campos($0)[1]?.bytes }
                let bien = self.candado.withLock { secreto != nil && secreto == self.secretoEsperado }
                if bien, let llave = llaveCliente.valor, let der = SecKeyCopyExternalRepresentation(llave, nil) as Data? {
                    self.candado.withLock { _ = self.emparejados.insert(der) }
                    self.responder(c, estado: 200) { $0.mensaje(41) { s in s.bytes(1, secreto!) } }
                } else {
                    // 402: STATUS_BAD_SECRET, como la tele real.
                    self.responder(c, estado: 402) { _ in }
                }
            }
        }
    }

    private func responder(_ c: NWConnection, estado: Int, _ armar: (inout Protobuf) -> Void) {
        mandar(c) { m in
            m.entero(1, 2)
            m.entero(2, estado)
            armar(&m)
        }
    }

    /// Como la tele: elige cuatro caracteres al azar y antepone el primer
    /// byte del hash, que sirve de dígito verificador.
    private func mostrarCodigo(para cliente: SecKey?) {
        guard let cliente,
              let suyos = Certificado.numeros(de: cliente),
              let nuestra = Certificado.llavePublica(de: identidad).flatMap(Certificado.numeros) else { return }
        let resto = String(format: "%04X", Int.random(in: 0...0xFFFF))
        var sha = SHA256()
        sha.update(data: suyos.modulo); sha.update(data: suyos.exponente)
        sha.update(data: nuestra.modulo); sha.update(data: nuestra.exponente)
        sha.update(data: Data(hex: resto)!)
        let hash = Data(sha.finalize())
        candado.withLock {
            secretoEsperado = hash
            codigoEnPantalla = String(format: "%02X", hash[0]) + resto
        }
    }

    // MARK: - Control

    private func atenderControl(_ c: NWConnection, _ llaveCliente: Caja<SecKey>) {
        let der = llaveCliente.valor.flatMap { SecKeyCopyExternalRepresentation($0, nil) as Data? }
        let conocido = candado.withLock { der.map(emparejados.contains) ?? false }
        guard conocido else {
            // Un teléfono que no emparejó: la tele corta sin decir nada.
            c.cancel()
            return
        }
        candado.withLock { controles.append(c) }
        mandar(c) { $0.mensaje(1) { r in r.entero(1, 622) } }
        leer(c) { [weak self] mensaje in
            guard let self else { return }
            let campos = Protobuf.campos(mensaje)
            if let conf = campos[1]?.bytes {
                let modelo = Protobuf.campos(conf)[2]?.bytes.flatMap { Protobuf.campos($0)[1]?.bytes }
                self.candado.withLock { self.configuradoPor = modelo.map { String(decoding: $0, as: UTF8.self) } }
                self.mandar(c) { $0.mensaje(2) { a in a.entero(1, 622) } }
            } else if campos[2] != nil {
                // Ya activo: el estado inicial y un ping, como la tele real.
                self.mandar(c) { $0.mensaje(40) { s in s.booleano(1, true) } }
                self.mandar(c) { $0.mensaje(50) { v in v.entero(6, 100); v.entero(7, 25); v.booleano(8, false) } }
                self.mandar(c) { $0.mensaje(20) { i in i.mensaje(1) { a in a.texto(12, "com.google.android.youtube.tv") } } }
                self.mandar(c) { $0.mensaje(8) { p in p.entero(1, 7) } }
            } else if let pong = campos[9]?.bytes {
                self.candado.withLock { self.pongs.append(Protobuf.campos(pong)[1]?.entero ?? 0) }
            } else if let tecla = campos[10]?.bytes {
                let codigo = Int(Protobuf.campos(tecla)[1]?.entero ?? 0)
                self.candado.withLock { self.teclas.append(codigo) }
            } else if let edicion = campos[21]?.bytes {
                let e = Protobuf.campos(edicion)
                let objeto = e[3]?.bytes.flatMap { Protobuf.campos($0)[2]?.bytes }
                let texto = objeto.flatMap { Protobuf.campos($0)[3]?.bytes }.map { String(decoding: $0, as: UTF8.self) } ?? ""
                self.candado.withLock {
                    self.escrito.append((texto, e[1]?.entero ?? 0, e[2]?.entero ?? 0))
                }
            } else if let enlace = campos[90]?.bytes {
                let texto = Protobuf.campos(enlace)[1]?.bytes.map { String(decoding: $0, as: UTF8.self) } ?? ""
                self.candado.withLock { self.enlaces.append(texto) }
            }
        }
    }
}
