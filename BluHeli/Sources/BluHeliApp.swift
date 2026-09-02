import SwiftUI
import ExternalAccessory
import UIKit

// =====================================================================
// BLUHELI MASTER v8 — ASISTENTE INTELIGENTE TIPO MANDO UNIVERSAL
// =====================================================================

// MARK: - Definición de los Formatos de Trama Candidatos
struct ProtocolCandidate: Identifiable {
    let id: Int
    let name: String
    let desc: String
    let builder: (Int, Int, Int, Int, Bool, Int) -> [UInt8] // (gas, pitch, yaw, trim, luz, match) -> bytes
}

enum ProtocolLibrary {
    static let candidates: [ProtocolCandidate] = [
        ProtocolCandidate(
            id: 1,
            name: "Formato 1: Bitmask Oficial Invertido (Little Endian)",
            desc: "Byte 0: Luz/Trim · Byte 1: Yaw · Byte 2: Pitch · Byte 3: Gas · Byte 4: 'x'",
            builder: { gas, pitch, yaw, trim, luz, match in
                let h = UInt8(0x78 | ((match & 3) << 6))
                let g = UInt8(Swift.max(0, Swift.min(128, gas)))
                let p = UInt8(Swift.max(0, Swift.min(255, pitch)))
                let y = UInt8(Swift.max(0, Swift.min(255, yaw)))
                let l = UInt8(luz ? 7 : 3)
                let lt = UInt8(((l & 7) << 5) | (UInt8(trim) & 0x1F))
                return [lt, y, p, g, h]
            }
        ),
        ProtocolCandidate(
            id: 2,
            name: "Formato 2: Cabecera 'x' Primero (Big Endian Oficial)",
            desc: "Byte 0: 'x' + Match · Byte 1: Gas (0..128) · Byte 2: Pitch · Byte 3: Yaw · Byte 4: Luz/Trim",
            builder: { gas, pitch, yaw, trim, luz, match in
                let h = UInt8(0x78 | ((match & 3) << 6))
                let g = UInt8(Swift.max(0, Swift.min(128, gas)))
                let p = UInt8(Swift.max(0, Swift.min(255, pitch)))
                let y = UInt8(Swift.max(0, Swift.min(255, yaw)))
                let l = UInt8(luz ? 7 : 3)
                let lt = UInt8(((l & 7) << 5) | (UInt8(trim) & 0x1F))
                return [h, g, p, y, lt]
            }
        ),
        ProtocolCandidate(
            id: 3,
            name: "Formato 3: Gas en Byte 4 (Layout Coche/Invertido)",
            desc: "Byte 0: 'x' + Match · Byte 1: Luz/Trim · Byte 2: Yaw · Byte 3: Pitch · Byte 4: Gas",
            builder: { gas, pitch, yaw, trim, luz, match in
                let h = UInt8(0x78 | ((match & 3) << 6))
                let g = UInt8(Swift.max(0, Swift.min(128, gas)))
                let p = UInt8(Swift.max(0, Swift.min(255, pitch)))
                let y = UInt8(Swift.max(0, Swift.min(255, yaw)))
                let l = UInt8(luz ? 7 : 3)
                let lt = UInt8(((l & 7) << 5) | (UInt8(trim) & 0x1F))
                return [h, lt, y, p, g]
            }
        ),
        ProtocolCandidate(
            id: 4,
            name: "Formato 4: Trama de 6 Bytes con Checksum",
            desc: "Byte 0..4: Datos Oficiales · Byte 5: Checksum (-sum(b0..b4))",
            builder: { gas, pitch, yaw, trim, luz, match in
                let h = UInt8(0x78 | ((match & 3) << 6))
                let g = UInt8(Swift.max(0, Swift.min(128, gas)))
                let p = UInt8(Swift.max(0, Swift.min(255, pitch)))
                let y = UInt8(Swift.max(0, Swift.min(255, yaw)))
                let l = UInt8(luz ? 7 : 3)
                let lt = UInt8(((l & 7) << 5) | (UInt8(trim) & 0x1F))
                let sum = Int(h) + Int(g) + Int(p) + Int(y) + Int(lt)
                let chk = UInt8((256 - (sum % 256)) & 0xFF)
                return [h, g, p, y, lt, chk]
            }
        ),
        ProtocolCandidate(
            id: 5,
            name: "Formato 5: Rango de Gas 64..128 (Offset Neutral)",
            desc: "Byte 0: 'x' · Byte 1: Gas donde 64=cero y 128=máximo",
            builder: { gas, pitch, yaw, trim, luz, match in
                let h = UInt8(0x78 | ((match & 3) << 6))
                let g = UInt8(Swift.max(64, Swift.min(128, 64 + (gas / 2))))
                let p = UInt8(Swift.max(0, Swift.min(255, pitch)))
                let y = UInt8(Swift.max(0, Swift.min(255, yaw)))
                let l = UInt8(luz ? 7 : 3)
                let lt = UInt8(((l & 7) << 5) | (UInt8(trim) & 0x1F))
                return [h, g, p, y, lt]
            }
        ),
        ProtocolCandidate(
            id: 6,
            name: "Formato 6: Potencia Completa Directa (0..255)",
            desc: "Byte 0: 'x' · Byte 1: Gas escalado a 255 · Byte 2: Pitch · Byte 3: Yaw",
            builder: { gas, pitch, yaw, trim, luz, match in
                let h = UInt8(0x78 | ((match & 3) << 6))
                let g = UInt8(Swift.max(0, Swift.min(255, gas * 2)))
                let p = UInt8(Swift.max(0, Swift.min(255, pitch)))
                let y = UInt8(Swift.max(0, Swift.min(255, yaw)))
                let l = UInt8(luz ? 7 : 3)
                let lt = UInt8(((l & 7) << 5) | (UInt8(trim) & 0x1F))
                return [h, g, p, y, lt]
            }
        ),
        ProtocolCandidate(
            id: 7,
            name: "Formato 7: Cabecera 0xB8 Fija (Banda B)",
            desc: "Byte 0: 0xB8 · Byte 1: Gas · Byte 2: Pitch · Byte 3: Yaw · Byte 4: Luz",
            builder: { gas, pitch, yaw, trim, luz, match in
                let g = UInt8(Swift.max(0, Swift.min(128, gas)))
                let p = UInt8(Swift.max(0, Swift.min(255, pitch)))
                let y = UInt8(Swift.max(0, Swift.min(255, yaw)))
                let l = UInt8(luz ? 0x78 : 0x38)
                return [0xB8, g, p, y, l]
            }
        ),
        ProtocolCandidate(
            id: 8,
            name: "Formato 8: Weccan Protocol (6 Bytes)",
            desc: "Byte 0: Luz · Byte 1: Trim · Byte 2: Yaw · Byte 3: Pitch · Byte 4: Gas · Byte 5: Flags",
            builder: { gas, pitch, yaw, trim, luz, match in
                let b0 = UInt8(luz ? 0xF0 : 0x00)
                let t = UInt8(Swift.max(0, Swift.min(32, trim)))
                let y = UInt8(Swift.max(0, Swift.min(255, yaw)))
                let p = UInt8(Swift.max(0, Swift.min(255, pitch)))
                let g = UInt8(Swift.max(0, Swift.min(255, gas * 2)))
                let flags = UInt8(((match & 3) << 6) | 0x2A)
                return [b0, t, y, p, g, flags]
            }
        )
    ]
}

// MARK: - Gestor de Comunicación MFi
final class HeliManager: NSObject, ObservableObject, StreamDelegate {
    @Published var conectado = false
    @Published var nombreDispositivo = ""
    @Published var protoActivo = ""
    @Published var log = ""
    @Published var framesEnviados = 0

    private var session: EASession?
    private var timerAutoConnect: Timer?

    override init() {
        super.init()
        EAAccessoryManager.shared().registerForLocalNotifications()
        NotificationCenter.default.addObserver(self, selector: #selector(accessoryConnected(_:)),
                                               name: .EAAccessoryDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(accessoryDisconnected(_:)),
                                               name: .EAAccessoryDidDisconnect, object: nil)

        timerAutoConnect = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
            guard let self = self, !self.conectado else { return }
            self.buscarYConectarAuto()
        }
    }

    deinit {
        timerAutoConnect?.invalidate()
    }

    @objc private func accessoryConnected(_ notification: Notification) {
        agregarLog("NOTIF: Accesorio MFi conectado.")
        buscarYConectarAuto()
    }

    @objc private func accessoryDisconnected(_ notification: Notification) {
        agregarLog("NOTIF: Accesorio desconectado.")
        cerrar()
    }

    func buscarYConectarAuto() {
        let accesorios = EAAccessoryManager.shared().connectedAccessories
        if accesorios.isEmpty { return }

        for acc in accesorios {
            let candidatos = ["com.silverlit.datapath", "com.issc.datapath", "com.silverlit.helicopter", "com.silverlit.ferrari"]
            for proto in candidatos {
                if acc.protocolStrings.contains(proto) {
                    if conectar(acc: acc, proto: proto) { return }
                }
            }
            if let primer = acc.protocolStrings.first {
                if conectar(acc: acc, proto: primer) { return }
            }
        }
    }

    func conectar(acc: EAAccessory, proto: String) -> Bool {
        cerrar()
        agregarLog("Abriendo enlace con \(acc.name) [\(proto)]...")
        guard let ses = EASession(accessory: acc, forProtocol: proto) else {
            agregarLog("Error al abrir EASession con '\(proto)'.")
            return false
        }

        session = ses
        nombreDispositivo = acc.name
        protoActivo = proto

        if let inp = ses.inputStream {
            inp.delegate = self
            inp.schedule(in: .main, forMode: .default)
            inp.open()
        }
        if let out = ses.outputStream {
            out.delegate = self
            out.schedule(in: .main, forMode: .default)
            out.open()
        }

        conectado = true
        agregarLog(">>> ¡CONECTADO A \(acc.name)! <<<")
        return true
    }

    func cerrar() {
        if let ses = session {
            ses.inputStream?.close()
            ses.outputStream?.close()
            ses.inputStream?.remove(from: .main, forMode: .default)
            ses.outputStream?.remove(from: .main, forMode: .default)
        }
        session = nil
        conectado = false
        nombreDispositivo = ""
        protoActivo = ""
    }

    func enviarTrama(_ bytes: [UInt8]) -> Bool {
        guard let out = session?.outputStream, out.hasSpaceAvailable else { return false }
        let n = out.write(bytes, maxLength: bytes.count)
        if n == bytes.count {
            framesEnviados += 1
            return true
        }
        return false
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .errorOccurred:
            DispatchQueue.main.async { self.agregarLog("STREAM: Error de enlace.") }
        case .endEncountered:
            DispatchQueue.main.async {
                self.agregarLog("STREAM: Conexión cerrada.")
                self.cerrar()
            }
        default: break
        }
    }

    func agregarLog(_ s: String) {
        let df = DateFormatter(); df.dateFormat = "HH:mm:ss"
        log = "[\(df.string(from: Date()))] \(s)\n" + log
        if log.count > 15000 { log = String(log.prefix(15000)) }
    }
}

// MARK: - Vista Principal
struct ContentView: View {
    @StateObject private var mgr = HeliManager()

    // Configuración persistente (guardada con UserDefaults)
    @AppStorage("configuracionCompletada") private var configuracionCompletada = false
    @AppStorage("canalSeleccionado") private var canalSeleccionado = 1       // 0=Rojo, 1=Verde, 2=Azul
    @AppStorage("formatoGanadorId") private var formatoGanadorId = 1         // ID de ProtocolCandidate

    // Estado del Asistente (Wizard)
    @State private var pasoWizard = 1 // 1=Color/Canal, 2=Motores, 3=Confirmación
    @State private var indiceCandidatoActual = 0
    @State private var probandoCodigo = false
    @State private var temporizadorPrueba = 0.0

    // Mandos de Vuelo Cockpit
    @State private var gas: Double = 0.0
    @State private var pitch: Double = 127.0
    @State private var yaw: Double = 127.0
    @State private var trim: Int = 10
    @State private var luces = true
    @State private var capSeguro = true
    @State private var modoVueloLibre = false
    @State private var rutinaEnCurso = false

    var candidatoActual: ProtocolCandidate {
        ProtocolLibrary.candidates[indiceCandidatoActual]
    }

    var candidatoGanador: ProtocolCandidate {
        ProtocolLibrary.candidates.first(where: { $0.id == formatoGanadorId }) ?? ProtocolLibrary.candidates[0]
    }

    var tramaActualVuelo: [UInt8] {
        let g = capSeguro ? Swift.min(Int(gas), 85) : Int(gas)
        return candidatoGanador.builder(g, Int(pitch), Int(yaw), trim, luces, canalSeleccionado)
    }

    var body: some View {
        TabView {
            if !configuracionCompletada {
                asistenteTab.tabItem {
                    Label("Configurar", systemImage: "wand.and.stars")
                }
            } else {
                cockpitTab.tabItem {
                    Label("Vuelo", systemImage: "airplane")
                }
            }

            ajustesTab.tabItem {
                Label("Ajustes", systemImage: "slider.horizontal.3")
            }

            consolaTab.tabItem {
                Label("Consola", systemImage: "terminal.fill")
            }
        }
        .onAppear {
            mgr.agregarLog("BluHeli Universal Wizard Iniciado.")
            mgr.buscarYConectarAuto()
            iniciarBucleVuelo()
        }
    }

    // =================================================================
    // TAB 1: ASISTENTE TIPO MANDO UNIVERSAL (Paso a Paso "¿Funciona? Sí/No")
    // =================================================================
    var asistenteTab: some View {
        NavigationView {
            Form {
                Section("Estado del Enlace") {
                    HStack {
                        Circle().fill(mgr.conectado ? Color.green : Color.red).frame(width: 14, height: 14)
                        Text(mgr.conectado ? "CONECTADO: \(mgr.nombreDispositivo)" : "BUSCANDO HELICÓPTERO...").bold()
                        Spacer()
                        Text("\(mgr.framesEnviados) tramas").font(.caption).foregroundColor(.secondary)
                    }
                }

                if pasoWizard == 1 {
                    // PASO 1: DETECCIÓN DE COLOR / BANDA
                    Section(header: Text("PASO 1 DE 2: IDENTIFICAR CANAL POR COLOR").bold()) {
                        Text("Elige un canal y pulsa 'Comprobar Color'. Mira de qué color se encienden las luces del helicóptero.")
                            .font(.footnote)
                            .foregroundColor(.secondary)

                        Picker("Canal a Probar", selection: $canalSeleccionado) {
                            Text("🔴 Canal A (LED Rojo)").tag(0)
                            Text("🟢 Canal B (LED Verde)").tag(1)
                            Text("🔵 Canal C (LED Azul)").tag(2)
                        }
                        .pickerStyle(.segmented)

                        Button(action: { comprobarColorCanal(canalSeleccionado) }) {
                            HStack {
                                Spacer()
                                Image(systemName: "lightbulb.fill").foregroundColor(.yellow)
                                Text("COMPROBAR CANAL \(nombreCanal(canalSeleccionado).uppercased())")
                                    .bold()
                                Spacer()
                            }
                        }
                        .buttonStyle(.borderedProminent)

                        VStack(alignment: .leading, spacing: 10) {
                            Text("¿El helicóptero se ha iluminado con este canal?").font(.subheadline).bold()
                            HStack {
                                Button("SÍ, ES ESTE COLOR ✅") {
                                    mgr.agregarLog("Canal \(nombreCanal(canalSeleccionado)) confirmado por el usuario.")
                                    pasoWizard = 2
                                    indiceCandidatoActual = 0
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.green)

                                Spacer()

                                Button("PROBAR OTRO CANAL 🔄") {
                                    canalSeleccionado = (canalSeleccionado + 1) % 3
                                    comprobarColorCanal(canalSeleccionado)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } else if pasoWizard == 2 {
                    // PASO 2: PRUEBA DE CÓDIGOS DE MOTOR (¿Hélices giraron? Sí / No)
                    Section(header: Text("PASO 2 DE 2: SINTONIZAR MOTOR (CÓDIGO \(indiceCandidatoActual + 1) DE \(ProtocolLibrary.candidates.count))").bold()) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(candidatoActual.name).bold().foregroundColor(.primary)
                            Text(candidatoActual.desc).font(.caption).foregroundColor(.secondary)
                        }

                        Button(action: { probarCodigoMotorActual() }) {
                            HStack {
                                Spacer()
                                if probandoCodigo {
                                    ProgressView().tint(.white).padding(.trailing, 4)
                                    Text("PROBANDO MOTOR AHORA...").bold()
                                } else {
                                    Image(systemName: "bolt.fill").foregroundColor(.yellow)
                                    Text("PROBAR ESTE CÓDIGO (GAS 95)").bold()
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(probandoCodigo ? .orange : .blue)
                        .disabled(probandoCodigo || !mgr.conectado)

                        VStack(alignment: .leading, spacing: 12) {
                            Text("¿HAN GIRADO LAS HÉLICES?").font(.headline).bold()

                            HStack(spacing: 16) {
                                Button(action: {
                                    // SÍ -> Guardar configuración y pasar a vuelo
                                    formatoGanadorId = candidatoActual.id
                                    configuracionCompletada = true
                                    mgr.agregarLog("¡CALIBRACIÓN EXITOSA! Guardado Formato \(candidatoActual.id).")
                                }) {
                                    HStack {
                                        Spacer()
                                        Image(systemName: "checkmark.circle.fill")
                                        Text("SÍ, ¡HAN GIRADO!").bold()
                                        Spacer()
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.green)

                                Button(action: {
                                    // NO -> Pasar al siguiente código
                                    if indiceCandidatoActual < ProtocolLibrary.candidates.count - 1 {
                                        indiceCandidatoActual += 1
                                        mgr.agregarLog("Probando siguiente candidato: Código \(indiceCandidatoActual + 1)...")
                                    } else {
                                        indiceCandidatoActual = 0
                                        mgr.agregarLog("Reiniciando ciclo de códigos...")
                                    }
                                }) {
                                    HStack {
                                        Spacer()
                                        Image(systemName: "xmark.circle")
                                        Text("NO, SIGUIENTE").bold()
                                        Spacer()
                                    }
                                }
                                .buttonStyle(.bordered)
                                .tint(.red)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
            .navigationTitle("Asistente Universal")
        }
    }

    // =================================================================
    // TAB 1 (Alternativo): COCKPIT DE VUELO DEFINITIVO
    // =================================================================
    var cockpitTab: some View {
        NavigationView {
            Form {
                Section("Estado de Vuelo") {
                    HStack {
                        Circle().fill(mgr.conectado ? Color.green : Color.red).frame(width: 14, height: 14)
                        VStack(alignment: .leading) {
                            Text(mgr.conectado ? "LISTO PARA VOLAR (\(candidatoGanador.name))" : "DESCONECTADO").bold()
                            Text("Canal: \(nombreCanal(canalSeleccionado))").font(.caption2).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Re-calibrar") {
                            configuracionCompletada = false
                            pasoWizard = 1
                        }
                        .font(.caption)
                    }
                }

                Section("Potencia (Acelerador)") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("GAS (Potencia)").bold()
                            Spacer()
                            Text("\(Int((gas / 128.0) * 100))% (\(Int(gas))/128)")
                                .font(.headline)
                                .foregroundColor(gas > 0 ? .green : .secondary)
                        }
                        Slider(value: $gas, in: 0...128, step: 1)
                            .tint(gas > 0 ? .green : .gray)
                    }

                    HStack {
                        Button("🛫 Despegue Suave (70%)") { ejecutarDespegueSuave() }
                            .buttonStyle(.bordered)
                            .tint(.green)
                            .disabled(rutinaEnCurso)

                        Spacer()

                        Button("🛬 Aterrizar") { ejecutarAterrizajeSuave() }
                            .buttonStyle(.bordered)
                            .tint(.blue)
                            .disabled(gas == 0 || rutinaEnCurso)
                    }
                }

                Section("Dirección (Pitch / Yaw / Trim)") {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("PITCH (Adelante/Atrás)").bold()
                            Spacer()
                            Text("\(Int(pitch))").font(.caption)
                        }
                        Slider(value: $pitch, in: 0...255, step: 1)
                    }

                    VStack(alignment: .leading) {
                        HStack {
                            Text("YAW (Giro de Cola)").bold()
                            Spacer()
                            Text("\(Int(yaw))").font(.caption)
                        }
                        Slider(value: $yaw, in: 0...255, step: 1)
                    }

                    HStack {
                        Picker("Trim", selection: $trim) {
                            ForEach(0..<21) { Text("\($0)").tag($0) }
                        }.pickerStyle(.menu)

                        Spacer()

                        Toggle("Luces", isOn: $luces).tint(.yellow)
                    }
                }

                Section {
                    Button(action: { paradaEmergencia() }) {
                        HStack {
                            Spacer()
                            Image(systemName: "stop.circle.fill")
                            Text("PARADA DE EMERGENCIA (STOP)").bold()
                            Spacer()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }

                Section {
                    HStack {
                        Text("TRAMA VUELO:")
                            .font(.caption2).foregroundColor(.secondary)
                        Spacer()
                        Text(tramaActualVuelo.map { String(format: "%02X", $0) }.joined(separator: " "))
                            .font(.system(.footnote, design: .monospaced))
                            .bold()
                            .foregroundColor(.blue)
                    }
                }
            }
            .navigationTitle("BluHeli Cockpit")
        }
    }

    // =================================================================
    // TAB 2: AJUSTES MANUALES
    // =================================================================
    var ajustesTab: some View {
        NavigationView {
            Form {
                Section("Configuración Guardada") {
                    Picker("Canal / Banda", selection: $canalSeleccionado) {
                        Text("🔴 Canal A (Rojo)").tag(0)
                        Text("🟢 Canal B (Verde)").tag(1)
                        Text("🔵 Canal C (Azul)").tag(2)
                    }

                    Picker("Perfil de Protocolo", selection: $formatoGanadorId) {
                        ForEach(ProtocolLibrary.candidates) { c in
                            Text(c.name).tag(c.id)
                        }
                    }

                    Toggle("Modo Seguro (Gas máx 85)", isOn: $capSeguro).tint(.orange)
                }

                Section("Acciones Rápidas") {
                    Button("🔄 Reiniciar Asistente de Configuración") {
                        configuracionCompletada = false
                        pasoWizard = 1
                        indiceCandidatoActual = 0
                    }
                    .foregroundColor(.orange)

                    Button("🛑 Parada Total Inmediata") {
                        paradaEmergencia()
                    }
                    .foregroundColor(.red)
                }
            }
            .navigationTitle("Ajustes")
        }
    }

    // =================================================================
    // TAB 3: CONSOLA Y LOGS
    // =================================================================
    var consolaTab: some View {
        NavigationView {
            Form {
                Section("Registro de Operaciones") {
                    TextEditor(text: $mgr.log)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 350)
                    HStack {
                        Button("Copiar Registro") {
                            UIPasteboard.general.string = mgr.log
                            mgr.agregarLog("Log copiado al portapapeles.")
                        }
                        Spacer()
                        Button("Limpiar") { mgr.log = "" }.foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Consola")
        }
    }

    // =================================================================
    // FUNCIONES DEL ASISTENTE Y VUELO
    // =================================================================
    func nombreCanal(_ m: Int) -> String {
        switch m {
        case 0: return "Rojo (A)"
        case 1: return "Verde (B)"
        case 2: return "Azul (C)"
        default: return "m\(m)"
        }
    }

    func iniciarBucleVuelo() {
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            if mgr.conectado && configuracionCompletada && !probandoCodigo && !rutinaEnCurso {
                _ = mgr.enviarTrama(tramaActualVuelo)
            }
        }
    }

    func comprobarColorCanal(_ canal: Int) {
        mgr.agregarLog("Probando sincronización en Canal \(nombreCanal(canal))...")
        // Enviar 10 tramas rápidas para iluminar los LEDs en el canal seleccionado
        for _ in 0..<10 {
            let pkt = candidatoActual.builder(0, 127, 127, 10, true, canal)
            _ = mgr.enviarTrama(pkt)
        }
    }

    func probarCodigoMotorActual() {
        probandoCodigo = true
        let cand = candidatoActual
        let canal = canalSeleccionado
        mgr.agregarLog("=== PROBANDO: \(cand.name) ===")
        mgr.agregarLog("1. Armado ESC (Gas 0 por 1.2s)...")

        var tick = 0
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { t in
            tick += 1
            if tick <= 24 {
                // Fase 1: Armado en Gas = 0 (1.2s)
                let pkt = cand.builder(0, 127, 127, 10, true, canal)
                _ = self.mgr.enviarTrama(pkt)
            } else if tick <= 65 {
                // Fase 2: Impulso de motor en Gas = 95 (2.0s)
                if tick == 25 { self.mgr.agregarLog("2. ¡POTENCIA A MOTORES (Gas 95)!...") }
                let pkt = cand.builder(95, 127, 127, 10, true, canal)
                _ = self.mgr.enviarTrama(pkt)
            } else {
                // Fase 3: Detener
                t.invalidate()
                let stopPkt = cand.builder(0, 127, 127, 10, true, canal)
                _ = self.mgr.enviarTrama(stopPkt)
                self.probandoCodigo = false
                self.mgr.agregarLog("Fin de prueba de \(cand.name). ¿Han girado las hélices?")
            }
        }
    }

    func ejecutarDespegueSuave() {
        rutinaEnCurso = true
        mgr.agregarLog("Despegue suave automático...")
        var paso = 0
        Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { t in
            paso += 1
            self.gas = Swift.min(85.0, Double(paso * 4))
            let pkt = self.candidatoGanador.builder(Int(self.gas), 127, 127, self.trim, self.luces, self.canalSeleccionado)
            _ = self.mgr.enviarTrama(pkt)
            if self.gas >= 85.0 {
                t.invalidate()
                self.rutinaEnCurso = false
                self.mgr.agregarLog("Despegue estabilizado.")
            }
        }
    }

    func ejecutarAterrizajeSuave() {
        rutinaEnCurso = true
        mgr.agregarLog("Aterrizando...")
        Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { t in
            self.gas = Swift.max(0.0, self.gas - 3.0)
            let pkt = self.candidatoGanador.builder(Int(self.gas), 127, 127, self.trim, self.luces, self.canalSeleccionado)
            _ = self.mgr.enviarTrama(pkt)
            if self.gas <= 0.0 {
                t.invalidate()
                self.gas = 0.0
                self.rutinaEnCurso = false
                self.mgr.agregarLog("Aterrizaje completado. Motor detenido.")
            }
        }
    }

    func paradaEmergencia() {
        rutinaEnCurso = false
        probandoCodigo = false
        gas = 0.0
        pitch = 127.0
        yaw = 127.0
        let stopPkt = candidatoGanador.builder(0, 127, 127, trim, luces, canalSeleccionado)
        _ = mgr.enviarTrama(stopPkt)
        mgr.agregarLog("🛑 PARADA DE EMERGENCIA EJECUTADA: Motores a 0.")
    }
}

@main
struct BluHeliApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
