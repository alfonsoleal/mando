import Foundation

/// Todo lo que se le puede pedir a un aparato. Cada controlador traduce lo que
/// entiende a su protocolo y responde `noSoportada` a lo demás.
nonisolated enum Orden: Equatable, Sendable {
    enum Direccion: Sendable { case arriba, abajo, izquierda, derecha }

    case mover(Direccion)
    case elegir
    case atras
    case inicio
    case playPausa
    case encender(Bool)
    case subirVolumen, bajarVolumen
    case volumen(Int)
    case silencio(Bool)
    case abrirApp(Aplicacion)
    case entrada(String)
    case modoSonido(String)
    case escribir(String)
}

/// Lo que un aparato avisa por su cuenta: alguien usó el control de fábrica,
/// el receptor cambió de entrada solo con HDMI-CEC, o contestó una pregunta.
nonisolated enum Reporte: Equatable, Sendable {
    case encendido(Bool)
    case volumen(Int)
    case silencio(Bool)
    /// La clave del protocolo, no el nombre de la casa.
    case entrada(String)
    case modoSonido(String)
    /// La app que está al frente, con el nombre que usa la casa.
    case app(String)
    /// Ya se puede mandar órdenes: la tele aceptó el permiso que pidió.
    case listo
    /// Dónde contestó: se guarda para conectar al instante la próxima vez.
    case direccion(host: String, puerto: UInt16)
    /// Lo que se está reproduciendo; nil cuando no hay nada.
    case reproduciendo(Reproduciendo?)
    /// La app que reproduce, por su identificador; la casa le pone nombre.
    case appPorId(String)
    /// Ver lo que se reproduce necesita un segundo emparejamiento (AirPlay).
    case reproduccionPorEmparejar(Bool)
}

/// Lo que el aparato está reproduciendo, como lo muestra la pantalla de
/// bloqueo del iPhone.
nonisolated struct Reproduciendo: Equatable, Sendable {
    var titulo: String
    /// «Severance · T2 E5» o el artista de una canción.
    var detalle: String?
    var duracion: TimeInterval?
    /// Lo transcurrido en el momento `medido`; con la velocidad se calcula el
    /// avance sin preguntarle a la tele cada segundo.
    var transcurrido: TimeInterval?
    var medido: Date = .now
    /// 1 reproduciendo, 0 en pausa.
    var velocidad: Double = 1
    var portada: Data?

    func transcurridoAhora(_ ahora: Date = .now) -> TimeInterval? {
        guard let transcurrido else { return nil }
        let avance = transcurrido + ahora.timeIntervalSince(medido) * velocidad
        return duracion.map { min(avance, $0) } ?? avance
    }
}
