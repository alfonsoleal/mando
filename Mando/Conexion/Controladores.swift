import Foundation

/// Arma el controlador de cada aparato a partir de su configuración, y borra
/// sus llaves cuando se olvida o se quita.
enum Controladores {
    static func para(_ a: Aparato) -> any Controlador {
        switch a.tipo {
        case .appleTV: ControladorAppleTV(host: a.host, puerto: a.puerto ?? 0, cuenta: a.llavero)
        case .googleTV: ControladorGoogleTV(host: a.host, nombreCertificado: a.llavero)
        case .onkyo: ControladorOnkyo(host: a.host)
        case .lg: ControladorLG(host: a.host, cuenta: a.llavero)
        }
    }

    static func olvidar(_ a: Aparato) {
        switch a.tipo {
        case .appleTV: Credenciales.borrar(a.llavero)
        // Con un certificado nuevo la tele ya no reconoce al teléfono.
        case .googleTV: Certificado.borrar(nombre: a.llavero)
        case .lg: Llavero.borrar(ControladorLG.servicio, a.llavero)
        case .onkyo: break
        }
    }
}
