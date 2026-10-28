import AVFoundation
import MediaPlayer
import SwiftUI

/// Los botones de volumen del iPhone mueven el volumen del aparato elegido
/// mientras Mando está abierta.
///
/// iOS no da un aviso de «apretaron el botón»: lo que sí avisa es que cambió
/// el volumen del teléfono. Se escucha ese cambio, se manda la orden y se
/// regresa el volumen del teléfono a la mitad, para que el siguiente toque
/// también se note (en el tope ya no cambiaría). Un MPVolumeView invisible
/// evita que aparezca el aviso de volumen del sistema. Al salir de la app, el
/// teléfono queda en el volumen que tenía.
@MainActor
final class BotonesFisicos {
    private var observacion: NSKeyValueObservation?
    private var volumenOriginal: Float?
    private var regresando = false
    private weak var deslizador: UISlider?
    private var alPresionar: ((Bool) -> Void)?

    private static let medio: Float = 0.5

    func activar(con deslizador: UISlider, alPresionar: @escaping (_ subir: Bool) -> Void) {
        guard observacion == nil else { return }
        self.deslizador = deslizador
        self.alPresionar = alPresionar
        let sesion = AVAudioSession.sharedInstance()
        // .ambient y mezclar: escuchar los botones no debe pausar la música
        // que suene en el teléfono.
        try? sesion.setCategory(.ambient, options: [.mixWithOthers])
        try? sesion.setActive(true)
        volumenOriginal = sesion.outputVolume
        poner(BotonesFisicos.medio)
        observacion = sesion.observe(\.outputVolume, options: [.old, .new]) { [weak self] _, cambio in
            guard let nuevo = cambio.newValue, let viejo = cambio.oldValue else { return }
            Task { @MainActor in self?.cambio(de: viejo, a: nuevo) }
        }
    }

    func desactivar() {
        observacion?.invalidate()
        observacion = nil
        if let volumenOriginal { poner(volumenOriginal) }
        volumenOriginal = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func cambio(de viejo: Float, a nuevo: Float) {
        // El cambio que provoca el propio regreso a la mitad no es un toque.
        if regresando {
            if abs(nuevo - BotonesFisicos.medio) < 0.01 { regresando = false }
            return
        }
        guard abs(nuevo - viejo) > 0.001 else { return }
        alPresionar?(nuevo > viejo)
        poner(BotonesFisicos.medio)
    }

    private func poner(_ valor: Float) {
        guard let deslizador, abs(deslizador.value - valor) > 0.001 else { return }
        regresando = true
        deslizador.value = valor
    }
}

/// El MPVolumeView que esconde el aviso de volumen del sistema y deja mover
/// el volumen del teléfono. Tiene que estar en pantalla, aunque no se vea.
struct VolumenInvisible: UIViewRepresentable {
    let listo: (UISlider) -> Void

    func makeUIView(context: Context) -> VistaDeVolumen {
        let vista = VistaDeVolumen()
        vista.alpha = 0.01
        vista.isUserInteractionEnabled = false
        vista.listo = listo
        return vista
    }

    func updateUIView(_ vista: VistaDeVolumen, context: Context) {}
}

/// iOS arma el deslizador del MPVolumeView hasta que la vista entra a una
/// ventana y se acomoda, y en versiones recientes lo mete en capas internas:
/// se busca en cada acomodo, en todo el árbol, hasta encontrarlo.
final class VistaDeVolumen: MPVolumeView {
    var listo: ((UISlider) -> Void)?
    private var entregado = false

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !entregado, window != nil, let deslizador = Self.buscar(en: self) else { return }
        entregado = true
        listo?(deslizador)
    }

    private static func buscar(en vista: UIView) -> UISlider? {
        for sub in vista.subviews {
            if let d = sub as? UISlider { return d }
            if let d = buscar(en: sub) { return d }
        }
        return nil
    }
}

extension View {
    /// Conecta los botones de volumen del iPhone con el aparato elegido
    /// mientras la app está al frente.
    func botonesDeVolumen(activos: Bool, alPresionar: @escaping (Bool) -> Void) -> some View {
        modifier(BotonesDeVolumen(activos: activos, alPresionar: alPresionar))
    }
}

private struct BotonesDeVolumen: ViewModifier {
    let activos: Bool
    let alPresionar: (Bool) -> Void

    @Environment(\.scenePhase) private var fase
    @State private var botones = BotonesFisicos()
    @State private var deslizador: UISlider?

    func body(content: Content) -> some View {
        content
            .background {
                if activos {
                    // Con 1×1 el sistema no arma el deslizador: necesita un
                    // tamaño de verdad. Se saca de la pantalla en vez de achicarlo.
                    VolumenInvisible { deslizador = $0 }
                        .frame(width: 120, height: 44)
                        .offset(x: -1000)
                        .accessibilityHidden(true)
                }
            }
            .onChange(of: deslizador) { revisar() }
            .onChange(of: fase) { revisar() }
            .onChange(of: activos) { revisar() }
    }

    private func revisar() {
        if activos, fase == .active, let deslizador {
            botones.activar(con: deslizador, alPresionar: alPresionar)
        } else {
            botones.desactivar()
        }
    }
}
