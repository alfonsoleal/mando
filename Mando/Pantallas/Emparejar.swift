import SwiftUI

/// Aviso sobre el control: la tele contesta pero no obedece hasta emparejar.
struct TarjetaEmparejar: View {
    let aparato: Aparato
    let emparejar: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Espacio.l) {
            Text("Se empareja una sola vez, con el código de la tele.")
                .font(Tipo.cuerpo)
                .foregroundStyle(Color.hueso)
            Button(action: emparejar) {
                Text("Emparejar")
                    .font(Tipo.tecla)
                    .foregroundStyle(Color.carbon)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Color.hueso, in: .rect(cornerRadius: Radio.tecla))
            }
            .buttonStyle(.plain)
        }
        .padding(Espacio.l)
        // El destacado de la pantalla: es lo único que hay que hacer antes de
        // que el control sirva.
        .tarjeta(radio: Radio.tecla, destacada: true)
    }
}

/// Casillas para el código de la tele. El ancho dice cuánto cabe, y el
/// teclado sólo acepta lo que puede venir: 4 números en el Apple TV, 6
/// números y letras de la A a la F en Google TV.
struct HojaEmparejar: View {
    @Environment(Casa.self) private var casa
    @Environment(\.dismiss) private var cerrar
    let id: Aparato.ID
    /// El segundo emparejamiento del Apple TV (AirPlay), para ver lo que se
    /// reproduce. Misma hoja, otro PIN.
    var paraReproduccion = false

    @State private var codigo = ""
    @State private var fase = Fase.pidiendo
    @State private var error: String?
    @FocusState private var enfocado: Bool

    enum Fase { case pidiendo, esperandoCodigo, confirmando }

    var body: some View {
        VStack(alignment: .leading, spacing: Espacio.xl) {
            VStack(alignment: .leading, spacing: Espacio.m) {
                Kicker(texto: "Emparejar \(casa[id]?.nombre ?? "")")
                Text("Escribe el código de la tele")
                    .font(Tipo.titulo)
                    .foregroundStyle(Color.hueso)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }

            casillas

            if let error {
                HStack(alignment: .top, spacing: Espacio.m) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Color.ambar)
                        .accessibilityHidden(true)
                    Text(error)
                        .font(Tipo.cuerpo)
                        .foregroundStyle(Color.hueso)
                }
            } else {
                Text(estado.uppercased())
                    .font(Tipo.etiqueta)
                    .tracking(1)
                    .foregroundStyle(Color.grisTexto)
            }

            Spacer(minLength: 0)

            VStack(spacing: Espacio.m) {
                Button(action: confirmar) {
                    Text(fase == .confirmando ? "Emparejando…" : "Emparejar")
                        .font(Tipo.tecla)
                        .foregroundStyle(Color.carbon)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Color.hueso.opacity(listo ? 1 : 0.35), in: .rect(cornerRadius: Radio.tecla))
                }
                .buttonStyle(.plain)
                .disabled(!listo)

                Button("Pedir otro código", action: pedir)
                    .font(Tipo.tecla)
                    .foregroundStyle(Color.hueso)
                    .frame(minHeight: 44)
                    .disabled(fase != .esperandoCodigo)
                    .opacity(fase == .esperandoCodigo ? 1 : 0.4)
            }
        }
        .padding(Espacio.xl)
        .presentationDetents([.medium, .large])
        .presentationBackground(Color.carbon)
        .task { pedir() }
    }

    private var listo: Bool { codigo.count == largo && fase == .esperandoCodigo }

    private var soloNumeros: Bool { casa[id]?.tipo == .appleTV }
    private var largo: Int { soloNumeros ? 4 : 6 }

    private var estado: String {
        switch fase {
        case .pidiendo: "Pidiendo el código a la tele…"
        case .esperandoCodigo: "La tele ya muestra el código"
        case .confirmando: "Comprobando…"
        }
    }

    private var casillas: some View {
        ZStack {
            // Un solo campo invisible lleva el texto; las casillas sólo lo
            // dibujan. Así funcionan pegar, borrar y el autollenado.
            TextField("", text: $codigo)
                .keyboardType(soloNumeros ? .numberPad : .asciiCapable)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .focused($enfocado)
                .opacity(0.01)
                .onChange(of: codigo) { _, nuevo in
                    let valido: (Character) -> Bool = soloNumeros ? \.isNumber : \.isHexDigit
                    let limpio = String(nuevo.uppercased().filter(valido).prefix(largo))
                    if limpio != nuevo { codigo = limpio }
                    error = nil
                }
                .onSubmit(confirmar)
                .accessibilityLabel("Código de \(largo) caracteres")

            HStack(spacing: Espacio.s) {
                ForEach(0..<largo, id: \.self) { i in
                    let letra = i < codigo.count ? String(Array(codigo)[i]) : ""
                    let actual = i == codigo.count && enfocado
                    Text(letra)
                        .font(Tipo.dato)
                        .foregroundStyle(Color.hueso)
                        .frame(maxWidth: .infinity, minHeight: 60)
                        .background(Color.panel, in: .rect(cornerRadius: Radio.tecla))
                        .overlay {
                            RoundedRectangle(cornerRadius: Radio.tecla)
                                .strokeBorder(actual ? Color.hueso.opacity(0.6) : Color.hilo, lineWidth: 1)
                        }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .contentShape(.rect)
        .onTapGesture { enfocado = true }
    }

    private func pedir() {
        fase = .pidiendo
        error = nil
        codigo = ""
        Task {
            let falla = paraReproduccion ? await casa.pedirCodigoReproduccion(id) : await casa.pedirCodigo(id)
            if let falla {
                error = falla
                fase = .esperandoCodigo
            } else {
                fase = .esperandoCodigo
                enfocado = true
            }
        }
    }

    private func confirmar() {
        guard listo else { return }
        fase = .confirmando
        Task {
            let falla = paraReproduccion
                ? await casa.emparejarReproduccion(id, codigo: codigo)
                : await casa.emparejar(id, codigo: codigo)
            if let falla {
                error = falla
                fase = .esperandoCodigo
            } else {
                cerrar()
            }
        }
    }
}

#Preview("Emparejar") {
    let casa = Casa.deMuestra(onkyo: ControladorDemo(tipo: .onkyo), googleTV: ControladorDemo(tipo: .googleTV), appleTV: ControladorDemo(tipo: .appleTV), lg: ControladorDemo(tipo: .lg))
    return Color.carbon
        .sheet(isPresented: .constant(true)) {
            HojaEmparejar(id: casa.aparatos.first { $0.tipo == .googleTV }!.id)
        }
        .environment(casa)
}

#Preview("Emparejar Apple TV") {
    let casa = Casa.deMuestra(onkyo: ControladorDemo(tipo: .onkyo), googleTV: ControladorDemo(tipo: .googleTV), appleTV: ControladorDemo(tipo: .appleTV), lg: ControladorDemo(tipo: .lg))
    return Color.carbon
        .sheet(isPresented: .constant(true)) {
            HojaEmparejar(id: casa.aparatos.first { $0.tipo == .appleTV }!.id)
        }
        .environment(casa)
}
