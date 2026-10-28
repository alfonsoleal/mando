import Foundation
import Security

/// Guardar y leer secretos pequeños (llaves de emparejamiento) en el Llavero.
/// Sobreviven a reinstalar la app, que es justo lo que se quiere: volver a
/// emparejar cada vez sería un estorbo.
nonisolated enum Llavero {
    static func leer(_ servicio: String, _ cuenta: String) -> Data? {
        var resultado: CFTypeRef?
        let consulta: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: servicio,
            kSecAttrAccount: cuenta,
            kSecReturnData: true,
        ]
        guard SecItemCopyMatching(consulta as CFDictionary, &resultado) == errSecSuccess else { return nil }
        return resultado as? Data
    }

    static func guardar(_ datos: Data, _ servicio: String, _ cuenta: String) {
        borrar(servicio, cuenta)
        SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: servicio,
            kSecAttrAccount: cuenta,
            kSecValueData: datos,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ] as CFDictionary, nil)
    }

    static func borrar(_ servicio: String, _ cuenta: String) {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: servicio,
            kSecAttrAccount: cuenta,
        ] as CFDictionary)
    }
}
