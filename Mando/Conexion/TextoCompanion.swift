import Foundation

/// El texto que se escribe en el Apple TV viaja como objetos de su sistema de
/// entrada (RemoteTextInput) archivados con NSKeyedArchiver. Aquí se arman con
/// clases propias a las que, al archivar, se les pone el nombre de las de
/// Apple: es el nombre lo que el Apple TV lee para reconstruirlas.
///
/// No se declaran con `@objc(RTITextOperations)` porque iOS puede tener ya
/// cargada una clase privada con ese nombre, y dos clases con el mismo nombre
/// en el proceso es buscarse problemas.
nonisolated enum TextoCompanion {
    /// Reemplaza el contenido del campo: primero se afirma que el texto es
    /// vacío y luego se inserta el nuevo. Así borrar en el teléfono también
    /// borra en la tele.
    static func borrar(sesion: UUID) throws -> Data {
        try archivar(Operaciones(sesion: sesion, salida: Salida(texto: nil), afirmar: ""))
    }

    static func insertar(_ texto: String, sesion: UUID) throws -> Data {
        try archivar(Operaciones(sesion: sesion, salida: Salida(texto: texto), afirmar: nil))
    }

    /// La sesión de texto que abrió el Apple TV, dentro del archivo que
    /// devuelve `_tiStart`. Se busca el único NSUUID del archivo en vez de
    /// reconstruir sus clases privadas.
    static func sesion(en archivo: Data) -> UUID? {
        guard let plist = try? PropertyListSerialization.propertyList(from: archivo, format: nil) as? [String: Any],
              let objetos = plist["$objects"] as? [Any] else { return nil }
        for objeto in objetos {
            if let d = objeto as? [String: Any], let bytes = d["NS.uuidbytes"] as? Data, bytes.count == 16 {
                return bytes.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
            }
        }
        return nil
    }

    private static func archivar(_ raiz: Operaciones) throws -> Data {
        let archivador = NSKeyedArchiver(requiringSecureCoding: true)
        archivador.setClassName("RTITextOperations", for: Operaciones.self)
        archivador.setClassName("TIKeyboardOutput", for: Salida.self)
        archivador.encode(raiz, forKey: NSKeyedArchiveRootObjectKey)
        archivador.finishEncoding()
        return archivador.encodedData
    }

    /// RTITextOperations: a qué sesión va y qué se escribe. El nombre de
    /// Objective-C es propio y estable; al archivar se cambia por el de Apple.
    @objc(MandoOperacionesDeTexto)
    final class Operaciones: NSObject, NSSecureCoding {
        static var supportsSecureCoding: Bool { true }
        let sesion: UUID
        let salida: Salida
        let afirmar: String?

        init(sesion: UUID, salida: Salida, afirmar: String?) {
            self.sesion = sesion
            self.salida = salida
            self.afirmar = afirmar
        }

        func encode(with c: NSCoder) {
            c.encode(salida, forKey: "keyboardOutput")
            c.encode(sesion as NSUUID, forKey: "targetSessionUUID")
            if let afirmar { c.encode(afirmar as NSString, forKey: "textToAssert") }
        }

        init?(coder c: NSCoder) {
            guard let s = c.decodeObject(of: NSUUID.self, forKey: "targetSessionUUID"),
                  let o = c.decodeObject(of: Salida.self, forKey: "keyboardOutput") else { return nil }
            sesion = s as UUID
            salida = o
            afirmar = c.decodeObject(of: NSString.self, forKey: "textToAssert") as String?
        }
    }

    /// TIKeyboardOutput: el texto a insertar.
    @objc(MandoSalidaDeTeclado)
    final class Salida: NSObject, NSSecureCoding {
        static var supportsSecureCoding: Bool { true }
        let texto: String?

        init(texto: String?) { self.texto = texto }

        func encode(with c: NSCoder) {
            if let texto { c.encode(texto as NSString, forKey: "insertionText") }
        }

        init?(coder c: NSCoder) {
            texto = c.decodeObject(of: NSString.self, forKey: "insertionText") as String?
        }
    }
}
