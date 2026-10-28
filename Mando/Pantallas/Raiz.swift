import SwiftUI

/// La app abre directo en el control del último aparato: lo que se hace con un
/// control es controlar, no escoger de una lista.
struct Raiz: View {
    @Environment(Casa.self) private var casa
    @State private var emparejando = false
    @State private var ajustes = false
    @State private var buscando = false
    /// Una preferencia del teléfono, no de la casa: por eso en UserDefaults.
    @AppStorage("botonesDeVolumen") private var usarBotonesDeVolumen = true

    var body: some View {
        Group {
            if let aparato = casa.actual {
                control(aparato)
            } else {
                PrimerUso { buscando = true }
            }
        }
        .background { FondoCarbon() }
        .overlay(alignment: .bottom) {
            if let aviso = casa.aviso {
                AvisoFlotante(texto: aviso)
                    .padding(.horizontal, Espacio.xl)
                    .padding(.bottom, Espacio.s)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: casa.aviso)
        .sheet(isPresented: $emparejando) {
            if let id = casa.seleccionado { HojaEmparejar(id: id) }
        }
        .sheet(isPresented: $ajustes) { Ajustes() }
        .sheet(isPresented: $buscando) {
            NavigationStack {
                BuscarAparatos()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Listo") { buscando = false }
                        }
                    }
            }
            .presentationBackground(Color.carbon)
        }
        .task { await casa.conectarTodos() }
        .botonesDeVolumen(activos: usarBotonesDeVolumen && casa.actual != nil) { subir in
            guard let id = casa.actual?.id else { return }
            casa.mandar(subir ? .subirVolumen : .bajarVolumen, a: id)
        }
    }

    private func control(_ aparato: Aparato) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                SelectorAparatos()
                BotonAjustes { ajustes = true }
                    .padding(.trailing, Espacio.l)
            }
            .padding(.top, Espacio.s)
            // Mismo ancho que el control, para que en iPad arranque en su columna.
            .frame(maxWidth: 460 + Espacio.xl * 2)
            GeometryReader { alto in
            ScrollView {
                VStack(alignment: .leading, spacing: Espacio.xl) {
                    Encabezado(aparato: aparato)
                    if case .sinConexion(let motivo) = aparato.conexion {
                        AvisoConexion(texto: motivo) {
                            Task { await casa.conectar(aparato.id) }
                        }
                    }
                    if aparato.conexion == .esperandoPermiso {
                        AvisoPermiso()
                    }
                    if aparato.conexion == .porEmparejar {
                        TarjetaEmparejar(aparato: aparato) { emparejando = true }
                    }
                    // Si el control cabe, se va hacia abajo: el título arriba
                    // y las teclas en la mitad de la pantalla que alcanza el pulgar.
                    Spacer(minLength: 0)
                    cuerpo(de: aparato)
                }
                .padding(.horizontal, Espacio.xl)
                .padding(.top, Espacio.xl)
                .padding(.bottom, Espacio.xxl)
                .frame(minHeight: alto.size.height, alignment: .top)
                // En iPad el control no se estira: se queda del ancho de una mano.
                .frame(maxWidth: 460)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .id(aparato.id)
            }
        }
    }

    @ViewBuilder
    private func cuerpo(de aparato: Aparato) -> some View {
        switch aparato.tipo {
        case .appleTV: ControlAppleTV(aparato: aparato)
        case .googleTV: ControlGoogleTV(aparato: aparato)
        case .onkyo, .lg: ControlAudio(aparato: aparato)
        }
    }
}

/// Las fichas de los aparatos, agrupadas por cuarto: el nombre del cuarto
/// va en mono antes de su grupo, como los kickers de la marca.
struct SelectorAparatos: View {
    @Environment(Casa.self) private var casa

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Espacio.s) {
                ForEach(casa.cuartos, id: \.self) { cuarto in
                    if casa.cuartos.count > 1, !cuarto.isEmpty {
                        Text(cuarto.uppercased())
                            .font(Tipo.etiqueta)
                            .tracking(1)
                            .foregroundStyle(Color.grisTexto)
                            .padding(.leading, cuarto == casa.cuartos.first ? 0 : Espacio.m)
                            .accessibilityAddTraits(.isHeader)
                    }
                    ForEach(casa.aparatos.filter { $0.cuarto == cuarto }) { aparato in
                        // Sin animación: cambiar de aparato tiene que ser instantáneo,
                        // y un fundido encima de teclas parece que algo se rompió.
                        Ficha(texto: aparato.nombre, activa: aparato.id == casa.actual?.id) {
                            casa.seleccionar(aparato.id)
                        }
                    }
                }
            }
            .padding(.horizontal, Espacio.xl)
        }
        .scrollIndicators(.hidden)
        // Las fichas se desvanecen contra el botón de ajustes en vez de
        // cortarse en seco: se ve que hay más y no parece un error.
        .mask {
            HStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: Espacio.xl)
            }
        }
    }
}

struct BotonAjustes: View {
    let accion: () -> Void

    var body: some View {
        Button(action: accion) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 17, weight: .light))
                .foregroundStyle(Color.hueso)
                .frame(width: 44, height: 44)
                .background(Color.panel, in: .circle)
                .overlay { Circle().strokeBorder(Color.hilo) }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ajustes")
    }
}

/// Con la casa vacía no hay control que mostrar: la única acción es buscar.
struct PrimerUso: View {
    let buscar: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Espacio.xl) {
            Spacer()
            Kicker(texto: "Mando")
            Text("Tus aparatos, en un \(Text("solo").font(Tipo.acento).foregroundStyle(Color.verde)) control")
                .font(Tipo.titulo)
                .foregroundStyle(Color.hueso)
            Text("Busco en tu red los Apple TV, Google TV, receptores Onkyo y teles LG. Tu teléfono tiene que estar en la misma Wi-Fi.")
                .font(Tipo.cuerpo)
                .foregroundStyle(Color.grisTexto)
            Spacer()
            Button(action: buscar) {
                Text("Buscar aparatos")
                    .font(Tipo.tecla)
                    .foregroundStyle(Color.carbon)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Color.hueso, in: .rect(cornerRadius: Radio.tecla))
            }
            .buttonStyle(.plain)
        }
        .padding(Espacio.xl)
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity)
    }
}

/// Dónde está, qué está pasando y el botón de encendido.
struct Encabezado: View {
    @Environment(Casa.self) private var casa
    let aparato: Aparato

    var body: some View {
        // Sólo el título: el cuarto y el aparato ya los dice el selector, y el
        // estado de la conexión lo dice el propio título cuando importa
        // («Buscando…», «Sin conexión»). Un renglón de «Conectado» en cada
        // pantalla era texto que nadie lee.
        HStack(alignment: .center, spacing: Espacio.l) {
            titulo
                // Una sola línea: si el título creciera con «Prime Video», todas
                // las teclas de abajo se moverían y el pulgar las pierde.
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            BotonEncendido(encendido: aparato.encendido && aparato.estadoConocido, conexion: aparato.conexion) {
                casa.mandar(.encender(!aparato.encendido), a: aparato.id)
            }
        }
    }

    /// «Viendo *Infuse*»: la palabra que cambia va en la serif verde, que es
    /// el acento de la marca y aquí dice lo único que importa de un vistazo.
    private var titulo: Text {
        let base = Text(verbo).font(Tipo.titulo).foregroundStyle(Color.hueso)
        // Un espacio en la serif aunque no haya acento: así el renglón mide lo
        // mismo con «Apagado» que con «Viendo Infuse» y las teclas no brincan.
        guard aparato.encendido, aparato.estadoConocido, let lo = queSuena else {
            return Text("\(base)\(Text(" ").font(Tipo.acento))")
        }
        return Text("\(base) \(Text(lo).font(Tipo.acento).foregroundStyle(Color.verde))")
    }

    private var verbo: String {
        switch aparato.conexion {
        case .sinConexion: return "Sin conexión"
        case .porEmparejar: return "Sin emparejar"
        case .esperandoPermiso: return "Acepta en la tele"
        case .conectando where !aparato.estadoConocido: return "Buscando…"
        default: break
        }
        // Conectado pero sin saber si está prendido (el Apple TV no siempre
        // lo dice): el nombre, que no afirma nada que no se sepa.
        guard aparato.estadoConocido else { return aparato.nombre }
        guard aparato.encendido else { return "Apagado" }
        guard queSuena != nil else { return aparato.nombre }
        return aparato.tipo == .onkyo ? "Escuchando" : "Viendo"
    }

    private var queSuena: String? {
        switch aparato.tipo {
        case .onkyo:
            aparato.entradas.first { $0.clave == aparato.entrada }?.nombre
        case .appleTV, .googleTV:
            aparato.appAbierta
        case .lg:
            nil
        }
    }
}

/// El botón de encendido dice dos cosas sin texto: el ícono en verde es que
/// hay conexión (gris mientras conecta o si no hay), y el aro hueso es que
/// el aparato está prendido. El fondo se queda oscuro siempre: un ícono verde
/// sobre hueso no se alcanzaría a ver.
struct BotonEncendido: View {
    let encendido: Bool
    let conexion: Conexion
    let accion: () -> Void
    @State private var toques = 0

    var body: some View {
        Button {
            toques += 1
            accion()
        } label: {
            Image(systemName: "power")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(conexion == .conectado ? Color.verde : Color.grisTexto)
                .frame(width: 52, height: 52)
                .background(Color.panel, in: .circle)
                .overlay {
                    Circle().strokeBorder(encendido ? Color.hueso : Color.hilo, lineWidth: encendido ? 1.5 : 1)
                }
                .contentShape(.circle)
                .animation(.snappy(duration: 0.2), value: conexion == .conectado)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .medium), trigger: toques)
        .accessibilityLabel(encendido ? "Apagar" : "Encender")
        .accessibilityValue(conexion == .conectado ? "Conectado" : "Sin conexión")
    }
}

/// Qué pasó, en una frase, y el cómo arreglarlo a un toque: el detalle
/// sirve la primera vez, pero no debe ocupar la pantalla cada vez.
struct AvisoConexion: View {
    let texto: String
    let reintentar: () -> Void
    @State private var abierto = false

    /// «No encontré el Onkyo en esta red.» + «Revisa que tenga…».
    private var partes: (titular: String, detalle: String?) {
        guard let corte = texto.range(of: ". ") else { return (texto, nil) }
        return (String(texto[..<corte.lowerBound]), String(texto[corte.upperBound...]))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Espacio.m) {
            HStack(alignment: .firstTextBaseline, spacing: Espacio.m) {
                Image(systemName: "wifi.exclamationmark")
                    .foregroundStyle(Color.ambar)
                    .accessibilityHidden(true)
                Text(partes.titular)
                    .font(Tipo.cuerpo)
                    .foregroundStyle(Color.hueso)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if abierto, let detalle = partes.detalle {
                Text(detalle)
                    .font(Tipo.cuerpo)
                    .foregroundStyle(Color.grisTexto)
            }
            HStack(spacing: Espacio.l) {
                if partes.detalle != nil {
                    Button(abierto ? "Ocultar" : "Cómo arreglarlo") {
                        withAnimation(.snappy) { abierto.toggle() }
                    }
                    .foregroundStyle(Color.grisTexto)
                }
                Spacer()
                Button("Reintentar", action: reintentar)
                    .foregroundStyle(Color.hueso)
            }
            .font(Tipo.tecla)
            .frame(minHeight: 44)
        }
        .padding(Espacio.l)
        .tarjeta(radio: Radio.tecla)
    }
}

struct AvisoFlotante: View {
    let texto: String

    var body: some View {
        HStack(spacing: Espacio.m) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Color.ambar)
                .accessibilityHidden(true)
            Text(texto)
                .font(Tipo.cuerpo)
                .foregroundStyle(Color.hueso)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Espacio.l)
        .background(Color.panelActivo, in: .rect(cornerRadius: Radio.tecla))
        .overlay { RoundedRectangle(cornerRadius: Radio.tecla).strokeBorder(Color.hilo) }
        // Flota sobre el control: la única sombra de la app, teñida de carbón.
        .shadow(color: Color.carbon.opacity(0.6), radius: 24, y: 8)
        .accessibilityAddTraits(.isStaticText)
    }
}

/// La tele pregunta en pantalla si deja entrar a Mando. No hay botón: lo que
/// falta se hace con el control de la tele, y la app se entera sola.
struct AvisoPermiso: View {
    var body: some View {
        HStack(alignment: .top, spacing: Espacio.m) {
            Image(systemName: "tv")
                .foregroundStyle(Color.hueso)
                .accessibilityHidden(true)
            Text("Acepta en la tele con su control.")
                .font(Tipo.cuerpo)
                .foregroundStyle(Color.hueso)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Espacio.l)
        .tarjeta(radio: Radio.tecla, destacada: true)
    }
}
