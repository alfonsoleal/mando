import SwiftUI

/// Los aparatos de la casa, por cuarto. Desde aquí se agregan, se editan y se
/// reordenan.
struct Ajustes: View {
    @Environment(Casa.self) private var casa
    @Environment(\.dismiss) private var cerrar
    @AppStorage("botonesDeVolumen") private var usarBotonesDeVolumen = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $usarBotonesDeVolumen) {
                        Text("Botones de volumen del iPhone")
                            .font(Tipo.cuerpo)
                            .foregroundStyle(Color.hueso)
                    }
                    .listRowBackground(Color.panel)
                } header: {
                    EncabezadoSeccion(texto: "Teléfono")
                } footer: {
                    Text("Con Mando abierta, mueven el volumen del aparato elegido.")
                        .font(Tipo.etiqueta)
                        .foregroundStyle(Color.grisTexto)
                }
                ForEach(casa.cuartos, id: \.self) { cuarto in
                    Section {
                        ForEach(casa.aparatos.filter { $0.cuarto == cuarto }) { aparato in
                            NavigationLink(value: aparato.id) { FilaAparato(aparato: aparato) }
                                .listRowBackground(Color.panel)
                        }
                    } header: {
                        EncabezadoSeccion(texto: cuarto.isEmpty ? "Sin cuarto" : cuarto)
                    }
                }
                Section {
                    NavigationLink {
                        BuscarAparatos()
                    } label: {
                        Label("Agregar aparato", systemImage: "plus")
                            .font(Tipo.cuerpo)
                            .foregroundStyle(Color.hueso)
                    }
                    .listRowBackground(Color.panel)
                }
            }
            .estiloCarbon()
            .navigationTitle("Ajustes")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Aparato.ID.self) { EditarAparato(id: $0) }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") { cerrar() }
                }
            }
        }
        .presentationBackground(Color.carbon)
    }
}

struct FilaAparato: View {
    let aparato: Aparato

    var body: some View {
        VStack(alignment: .leading, spacing: Espacio.xs) {
            Text(aparato.nombre)
                .font(Tipo.cuerpo)
                .foregroundStyle(Color.hueso)
            Text(detalle.uppercased())
                .font(Tipo.etiqueta)
                .tracking(1)
                .foregroundStyle(Color.grisTexto)
        }
        .padding(.vertical, Espacio.xs)
    }

    private var detalle: String {
        [aparato.tipo.nombre, aparato.host].compactMap { $0 }.joined(separator: " · ")
    }
}

struct EncabezadoSeccion: View {
    let texto: String
    var body: some View {
        Text(texto.uppercased())
            .font(Tipo.etiqueta)
            .tracking(1.2)
            .foregroundStyle(Color.grisTexto)
    }
}

// MARK: - Agregar

/// Busca en la red y va mostrando lo que encuentra. Lo que ya está en la casa
/// se marca, para no agregarlo dos veces.
struct BuscarAparatos: View {
    @Environment(Casa.self) private var casa
    @State private var encontrados: [Descubridor.Encontrado] = []
    @State private var buscando = true
    @State private var agregado: Aparato.ID?

    var body: some View {
        Form {
            Section {
                ForEach(encontrados) { e in
                    HStack(spacing: Espacio.m) {
                        VStack(alignment: .leading, spacing: Espacio.xs) {
                            Text(nombre(de: e))
                                .font(Tipo.cuerpo)
                                .foregroundStyle(Color.hueso)
                            Text("\(e.tipo.nombre) · \(e.host)".uppercased())
                                .font(Tipo.etiqueta)
                                .tracking(1)
                                .foregroundStyle(Color.grisTexto)
                        }
                        Spacer()
                        if yaEsta(e) {
                            Text("YA ESTÁ")
                                .font(Tipo.etiqueta)
                                .foregroundStyle(Color.grisTexto)
                        } else {
                            Button("Agregar") { agregar(e) }
                                .font(Tipo.tecla)
                                .foregroundStyle(Color.hueso)
                                .frame(minHeight: 44)
                        }
                    }
                    .listRowBackground(Color.panel)
                }
                if buscando {
                    HStack(spacing: Espacio.m) {
                        ProgressView().tint(Color.hueso)
                        Text("Buscando en tu red…")
                            .font(Tipo.cuerpo)
                            .foregroundStyle(Color.grisTexto)
                    }
                    .listRowBackground(Color.panel)
                } else if encontrados.isEmpty {
                    Text("No encontré nada. Revisa que estén prendidos y en esta Wi-Fi.")
                        .font(Tipo.cuerpo)
                        .foregroundStyle(Color.hueso)
                        .listRowBackground(Color.panel)
                }
            } header: {
                EncabezadoSeccion(texto: "En tu red")
            }

            Section {
                ForEach(TipoAparato.allCases, id: \.self) { tipo in
                    Button {
                        let nuevo = Catalogo.nuevo(tipo)
                        casa.agregar(nuevo)
                        agregado = nuevo.id
                    } label: {
                        Text(tipo.nombre)
                            .font(Tipo.cuerpo)
                            .foregroundStyle(Color.hueso)
                    }
                    .listRowBackground(Color.panel)
                }
            } header: {
                EncabezadoSeccion(texto: "A mano")
            } footer: {
                Text("La app lo busca sola al conectar.")
                    .font(Tipo.etiqueta)
                    .foregroundStyle(Color.grisTexto)
            }
        }
        .estiloCarbon()
        .navigationTitle("Agregar aparato")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $agregado) { EditarAparato(id: $0) }
        .task {
            for await e in Descubridor.buscar() where !encontrados.contains(e) {
                encontrados.append(e)
            }
            buscando = false
        }
    }

    /// El nombre del anuncio si dice algo («Sala»); si es un nombre de equipo
    /// («appletv», «Android-7f3a»), el del tipo.
    private func nombre(de e: Descubridor.Encontrado) -> String {
        let n = e.nombre.trimmingCharacters(in: .whitespaces)
        let generico = n.isEmpty || n.lowercased().replacingOccurrences(of: " ", with: "") == e.tipo.nombre.lowercased().replacingOccurrences(of: " ", with: "")
            || n.contains("-") || n == n.lowercased()
        return generico ? e.tipo.nombre : n
    }

    private func yaEsta(_ e: Descubridor.Encontrado) -> Bool {
        casa.aparatos.contains { $0.tipo == e.tipo && $0.host == e.host }
    }

    private func agregar(_ e: Descubridor.Encontrado) {
        let nuevo = Catalogo.nuevo(e.tipo, nombre: nombre(de: e), host: e.host, puerto: e.puerto)
        casa.agregar(nuevo)
        // Directo a su configuración: lo primero que hace falta es el cuarto.
        agregado = nuevo.id
    }
}

// MARK: - Editar

/// La configuración de un aparato. Se guarda sola en cada cambio; la
/// dirección, sólo al terminar de escribirla, para no reconectar con cada letra.
struct EditarAparato: View {
    @Environment(Casa.self) private var casa
    @Environment(\.dismiss) private var cerrar
    let id: Aparato.ID

    @State private var borrador: Aparato?
    @State private var direccion = ""
    @State private var trayendoApps = false
    @State private var errorApps: String?
    @State private var confirmarOlvidar = false
    @State private var confirmarQuitar = false

    var body: some View {
        Group {
            if let borrador {
                formulario(borrador)
            }
        }
        .estiloCarbon()
        .navigationTitle(borrador?.nombre ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let b = borrador, !b.entradas.isEmpty || !b.apps.isEmpty {
                ToolbarItem(placement: .primaryAction) { EditButton() }
            }
        }
        .onAppear {
            borrador = casa[id]
            direccion = casa[id]?.host ?? ""
        }
        .onChange(of: borrador) { _, nuevo in
            if let nuevo { casa.actualizar(nuevo) }
        }
    }

    @ViewBuilder
    private func formulario(_ a: Aparato) -> some View {
        Form {
            Section {
                campo("Nombre", texto: enlace(\.nombre))
                VStack(alignment: .leading, spacing: Espacio.m) {
                    campo("Cuarto", texto: enlace(\.cuarto))
                    let otros = casa.cuartos.filter { !$0.isEmpty && $0 != a.cuarto }
                    if !otros.isEmpty {
                        ScrollView(.horizontal) {
                            HStack(spacing: Espacio.s) {
                                ForEach(otros, id: \.self) { c in
                                    Ficha(texto: c) { borrador?.cuarto = c }
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                    }
                }
                .listRowBackground(Color.panel)
            } header: {
                EncabezadoSeccion(texto: "Aparato")
            }

            if !a.tipo.llevaVolumen || a.tipo == .lg && !casa.quienesLlevanVolumen(de: id).isEmpty {
                seccionVolumen(a)
            }

            if !a.entradas.isEmpty { seccionEntradas() }
            if !a.modos.isEmpty { seccionModos() }
            if !a.apps.isEmpty || a.tipo == .appleTV { seccionApps(a) }

            Section {
                HStack {
                    Text("IP")
                        .font(Tipo.cuerpo)
                        .foregroundStyle(Color.hueso)
                    TextField("La busca sola", text: $direccion)
                        .font(Tipo.dato)
                        .foregroundStyle(Color.hueso)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .submitLabel(.done)
                        .onSubmit {
                            let limpio = direccion.trimmingCharacters(in: .whitespaces)
                            borrador?.host = limpio.isEmpty ? nil : limpio
                            // Una IP escrita a mano no trae puerto: el Apple TV
                            // lo vuelve a leer de su anuncio.
                            if a.tipo == .appleTV { borrador?.puerto = nil }
                        }
                }
                .listRowBackground(Color.panel)
                if a.tipo != .onkyo {
                    Button("Olvidar emparejamiento") { confirmarOlvidar = true }
                        .font(Tipo.cuerpo)
                        .foregroundStyle(Color.hueso)
                        .listRowBackground(Color.panel)
                }
                Button("Quitar aparato", role: .destructive) { confirmarQuitar = true }
                    .font(Tipo.cuerpo)
                    .listRowBackground(Color.panel)
            } header: {
                EncabezadoSeccion(texto: "Conexión")
            } footer: {
                Text("Si cambia de IP, la app lo vuelve a buscar.")
                    .font(Tipo.etiqueta)
                    .foregroundStyle(Color.grisTexto)
            }
        }
        .confirmationDialog("¿Olvidar el emparejamiento de \(a.nombre)?", isPresented: $confirmarOlvidar, titleVisibility: .visible) {
            Button("Olvidar", role: .destructive) { casa.olvidarEmparejamiento(id) }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Al conectar, la tele vuelve a pedir el código o el permiso.")
        }
        .confirmationDialog("¿Quitar \(a.nombre) de la casa?", isPresented: $confirmarQuitar, titleVisibility: .visible) {
            Button("Quitar", role: .destructive) {
                borrador = nil
                casa.quitar(id)
                cerrar()
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("También se borra su emparejamiento.")
        }
    }

    // MARK: Secciones

    private func seccionVolumen(_ a: Aparato) -> some View {
        let opciones = casa.quienesLlevanVolumen(de: id)
        let receptor = a.volumenEn.flatMap { casa[$0] }
        return Section {
            Picker(selection: enlace(\.volumenEn)) {
                Text(a.tipo == .appleTV ? "La tele, por HDMI-CEC" : "Este aparato").tag(UUID?.none)
                ForEach(opciones) { o in
                    Text(o.nombre).tag(UUID?.some(o.id))
                }
            } label: {
                Text("Lo lleva").font(Tipo.cuerpo).foregroundStyle(Color.hueso)
            }
            .listRowBackground(Color.panel)
            .onChange(of: a.volumenEn) { borrador?.entradaAlElegir = nil }

            if let receptor, !receptor.entradasVisibles.isEmpty {
                Picker(selection: enlace(\.entradaAlElegir)) {
                    Text("No cambiarla").tag(String?.none)
                    ForEach(receptor.entradasVisibles) { e in
                        Text("\(e.nombre) (\(e.etiqueta))").tag(String?.some(e.clave))
                    }
                } label: {
                    Text("Entrada al elegirlo").font(Tipo.cuerpo).foregroundStyle(Color.hueso)
                }
                .listRowBackground(Color.panel)
            }
        } header: {
            EncabezadoSeccion(texto: "Volumen")
        } footer: {
            Text("A quién le hablan sus teclas de volumen.")
                .font(Tipo.etiqueta)
                .foregroundStyle(Color.grisTexto)
        }
    }

    private func seccionEntradas() -> some View {
        Section {
            ForEach(Binding(get: { borrador?.entradas ?? [] }, set: { borrador?.entradas = $0 })) { $e in
                HStack(spacing: Espacio.m) {
                    Text(e.etiqueta)
                        .font(Tipo.etiqueta)
                        .foregroundStyle(Color.grisTexto)
                        .frame(width: 84, alignment: .leading)
                    TextField(e.etiqueta, text: $e.nombre)
                        .font(Tipo.cuerpo)
                        .foregroundStyle(e.visible ? Color.hueso : Color.grisTexto)
                    Toggle("Mostrar", isOn: $e.visible).labelsHidden()
                }
                .listRowBackground(Color.panel)
            }
            .onMove { borrador?.entradas.move(fromOffsets: $0, toOffset: $1) }
        } header: {
            EncabezadoSeccion(texto: "Entradas")
        } footer: {
            Text("Las apagadas no salen en el control.")
                .font(Tipo.etiqueta)
                .foregroundStyle(Color.grisTexto)
        }
    }

    private func seccionModos() -> some View {
        Section {
            ForEach(Binding(get: { borrador?.modos ?? [] }, set: { borrador?.modos = $0 })) { $m in
                Toggle(isOn: $m.visible) {
                    Text(m.nombre).font(Tipo.cuerpo).foregroundStyle(Color.hueso)
                }
                .listRowBackground(Color.panel)
            }
        } header: {
            EncabezadoSeccion(texto: "Modos de sonido")
        }
    }

    private func seccionApps(_ a: Aparato) -> some View {
        Section {
            ForEach(Binding(get: { borrador?.apps ?? [] }, set: { borrador?.apps = $0 })) { $app in
                Toggle(isOn: $app.visible) {
                    Text(app.nombre).font(Tipo.cuerpo).foregroundStyle(Color.hueso)
                }
                .listRowBackground(Color.panel)
            }
            .onMove { borrador?.apps.move(fromOffsets: $0, toOffset: $1) }
            if a.tipo == .appleTV {
                Button {
                    Task { await traerApps() }
                } label: {
                    HStack(spacing: Espacio.m) {
                        Text(trayendoApps ? "Preguntando al Apple TV…" : "Traer las apps del Apple TV")
                            .font(Tipo.cuerpo)
                            .foregroundStyle(Color.hueso)
                        if trayendoApps { ProgressView().tint(Color.hueso) }
                    }
                }
                .disabled(trayendoApps)
                .listRowBackground(Color.panel)
                if let errorApps {
                    Text(errorApps)
                        .font(Tipo.cuerpo)
                        .foregroundStyle(Color.hueso)
                        .listRowBackground(Color.panel)
                }
            }
        } header: {
            EncabezadoSeccion(texto: "Apps")
        } footer: {
            Text("Las apagadas no salen en el control.")
                .font(Tipo.etiqueta)
                .foregroundStyle(Color.grisTexto)
        }
    }

    /// Agrega las que falten sin tocar las que ya están, para no perder el
    /// orden ni lo que se ocultó. Las nuevas llegan apagadas: un Apple TV
    /// trae docenas de apps y el control quiere cinco.
    private func traerApps() async {
        trayendoApps = true
        errorApps = nil
        defer { trayendoApps = false }
        do {
            guard let instaladas = try await casa.appsInstaladas(id) else { return }
            var lista = borrador?.apps ?? []
            for app in instaladas where !lista.contains(where: { $0.id == app.id }) {
                var nueva = app
                nueva.visible = false
                lista.append(nueva)
            }
            borrador?.apps = lista
        } catch {
            errorApps = error.localizedDescription
        }
    }

    // MARK: Ayudantes

    private func enlace<T>(_ ruta: WritableKeyPath<Aparato, T>) -> Binding<T> {
        Binding(
            get: { borrador![keyPath: ruta] },
            set: { borrador?[keyPath: ruta] = $0 }
        )
    }

    private func campo(_ etiqueta: String, texto: Binding<String>) -> some View {
        HStack {
            Text(etiqueta)
                .font(Tipo.cuerpo)
                .foregroundStyle(Color.grisTexto)
            TextField(etiqueta, text: texto)
                .font(Tipo.cuerpo)
                .foregroundStyle(Color.hueso)
                .multilineTextAlignment(.trailing)
        }
        .listRowBackground(Color.panel)
    }
}

extension View {
    /// Los formularios de ajustes con la marca: carbón de fondo, filas en
    /// panel y el texto del sistema en hueso.
    func estiloCarbon() -> some View {
        scrollContentBackground(.hidden)
            .background { FondoCarbon() }
            .toolbarBackground(Color.carbon, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .tint(Color.hueso)
            // Encendido en verde, como lo espera la mano: en hueso el botón
            // blanco desaparece sobre su propio fondo.
            .toggleStyle(SwitchToggleStyle(tint: Color.verde))
    }
}
