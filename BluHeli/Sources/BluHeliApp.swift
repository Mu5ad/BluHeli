import SwiftUI
import ExternalAccessory
import UIKit

// =====================================================================
// BLUHELI PILOT DEFINITIVO v10 — ARQUITECTURA REACTIVA INTEGRAL EN CLASE
// Protocolo Confirmado: Weccan 6-Bytes en Canal C (Azul / Match 2)
// =====================================================================

final class HeliPilot: NSObject, ObservableObject, StreamDelegate {
    // Estado del Enlace Bluetooth
    @Published var conectado = false
    @Published var nombreDispositivo = ""
    @Published var protoActivo = ""
    @Published var log = ""
    @Published var framesEnviados = 0
    @Published var ultimaTramaHex = ""

    // Parámetros de Vuelo Reactivos (Gestionados en el Heap de la Clase)
    @Published var gas: Double = 0.0          // 0% a 100% de potencia
    @Published var pitch: Double = 127.0      // 0..255 (127 neutro)
    @Published var yaw: Double = 127.0        // 0..255 (127 neutro)
    @Published var trim: Int = 16             // 0..32 (16 neutro de Weccan i737)
    @Published var match: Int = 2             // 0=Rojo(A), 1=Verde(B), 2=Azul(C - Confirmado)
    @Published var luces: Bool = true         // Faros encendidos
    @Published var maniobraActiva = false     // Bloquea comandos manuales durante rutinas

    private var session: EASession?
    private var timerAutoConnect: Timer?
    private var timerTransmision20Hz: Timer?

    override init() {
        super.init()
        EAAccessoryManager.shared().registerForLocalNotifications()
        NotificationCenter.default.addObserver(self, selector: #selector(accesorioConectado(_:)),
                                               name: .EAAccessoryDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(accesorioDesconectado(_:)),
                                               name: .EAAccessoryDidDisconnect, object: nil)

        // Bucle de búsqueda de reconexión continua cada 1.5s
        timerAutoConnect = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self = self, !self.conectado else { return }
            self.buscarYConectarAuto()
        }

        // BUCLE DE TRANSMISIÓN CONTINUA A 20Hz (DIRECTO EN LA CLASE)
        // Al ejecutarse dentro de HeliPilot (class), NUNCA captura datos congelados
        timerTransmision20Hz = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self, self.conectado else { return }
            self.enviarTramaVueloActual()
        }
    }

    deinit {
        timerAutoConnect?.invalidate()
        timerTransmision20Hz?.invalidate()
    }

    @objc private func accesorioConectado(_ notification: Notification) {
        agregarLog("NOTIF: Helicóptero detectado por iOS.")
        buscarYConectarAuto()
    }

    @objc private func accesorioDesconectado(_ notification: Notification) {
        agregarLog("NOTIF: Helicóptero desconectado.")
        cerrarSesion()
    }

    // Selector Bluetooth nativo de Apple para cuando el heli se apaga y se vuelve a encender
    func abrirSelectorBluetoothMFi() {
        agregarLog("Abriendo selector Bluetooth MFi de Apple...")
        EAAccessoryManager.shared().showBluetoothAccessoryPicker(withPredicate: nil, completion: { [weak self] (error: Error?) in
            if let err = error {
                self?.agregarLog("Selector MFi: \(err.localizedDescription)")
            } else {
                self?.agregarLog("Accesorio seleccionado en el diálogo MFi.")
                self?.buscarYConectarAuto()
            }
        })
    }

    func buscarYConectarAuto() {
        let accesorios = EAAccessoryManager.shared().connectedAccessories
        if accesorios.isEmpty { return }

        for acc in accesorios {
            let protocolosValidos = ["com.silverlit.datapath", "com.issc.datapath", "com.silverlit.helicopter", "com.silverlit.ferrari"]
            for proto in protocolosValidos {
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
        cerrarSesion()
        agregarLog("Conectando con \(acc.name) [\(proto)]...")
        guard let ses = EASession(accessory: acc, forProtocol: proto) else {
            agregarLog("Error: No se pudo abrir EASession con '\(proto)'.")
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
        agregarLog(">>> ¡CONECTADO A \(acc.name)! Enlace a 20Hz ACTIVO. <<<")
        return true
    }

    func cerrarSesion() {
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
        gas = 0.0
    }

    // =================================================================
    // GENERADOR DE TRAMA WECCAN 6-BYTES (VERIFICADO EN BUILD 16)
    // =================================================================
    func generarBytesWeccan(gasPorcentaje: Double, pitchVal: Double, yawVal: Double, trimVal: Int, luzVal: Bool, matchCanal: Int) -> [UInt8] {
        let b0: UInt8 = luzVal ? 0xF0 : 0x00
        let t = UInt8(Swift.max(0, Swift.min(32, trimVal)))
        let y = UInt8(Swift.max(0, Swift.min(255, Int(yawVal))))
        let p = UInt8(Swift.max(0, Swift.min(255, Int(pitchVal))))
        
        // Mapeo real de potencia: 0% = 0, 100% = 240 sobre 255
        let potenciaCalculada = gasPorcentaje > 0 ? (gasPorcentaje / 100.0) * 240.0 : 0.0
        let g = UInt8(Swift.max(0, Swift.min(255, Int(potenciaCalculada))))
        
        // Flags: Match en bits 6..7, 0x2A en bits 0..5 (Exacto a Build 16)
        let flags = UInt8(((matchCanal & 3) << 6) | 0x2A)
        return [b0, t, y, p, g, flags]
    }

    func enviarTramaVueloActual() {
        let bytes = generarBytesWeccan(gasPorcentaje: gas, pitchVal: pitch, yawVal: yaw, trimVal: trim, luzVal: luces, matchCanal: match)
        _ = escribirBytes(bytes)
    }

    func escribirBytes(_ bytes: [UInt8]) -> Bool {
        guard let out = session?.outputStream, out.hasSpaceAvailable else { return false }
        let n = out.write(bytes, maxLength: bytes.count)
        if n == bytes.count {
            framesEnviados += 1
            ultimaTramaHex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            return true
        }
        return false
    }

    // =================================================================
    // ACCIONES DE VUELO Y MANIOBRAS ASISTIDAS
    // =================================================================

    // 1. EL TEST QUE HIZO VOLAR EL HELICÓPTERO (Con parada segura garantizada)
    func ejecutarTestVuelo2Segundos(potencia: Double = 75.0) {
        guard conectado else {
            agregarLog("Error: Helicóptero no conectado. Pulsa reconectar.")
            return
        }
        maniobraActiva = true
        agregarLog("=== INICIANDO PULSO DE VUELO WECCAN (POTENCIA \(Int(potencia))%) ===")
        agregarLog("1. Armado ESC (Gas = 0 por 1.0s)...")

        gas = 0.0
        var tick = 0
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            tick += 1
            if tick <= 20 {
                // 1.0s en Gas = 0 para desbloquear ESC
                self.gas = 0.0
            } else if tick <= 60 {
                // 2.0s de Potencia Real
                if tick == 21 { self.agregarLog("2. ¡POTENCIA A MOTORES (Gas \(Int(potencia))%)!...") }
                self.gas = potencia
            } else {
                // Parada y Failsafe
                t.invalidate()
                self.gas = 0.0
                self.maniobraActiva = false
                self.agregarLog("3. Fin de pulso. Motor detenido a 0%.")
            }
        }
    }

    // 2. DESPEGUE SUAVE ASISTIDO (Asciende gradualmente hasta sustentación)
    func despegueSuave() {
        guard conectado else { return }
        maniobraActiva = true
        agregarLog("Iniciando despegue suave progresivo...")
        gas = 0.0
        var paso = 0
        Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            paso += 1
            self.gas = Swift.min(56.0, Double(paso * 3))
            if self.gas >= 56.0 {
                t.invalidate()
                self.maniobraActiva = false
                self.agregarLog("Despegue estabilizado a 56% de potencia.")
            }
        }
    }

    // 3. ATERRIZAJE ASISTIDO (Desciende poco a poco hasta posarse)
    func aterrizarSuave() {
        guard conectado else { return }
        maniobraActiva = true
        agregarLog("Iniciando aterrizaje suave...")
        Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            self.gas = Swift.max(0.0, self.gas - 3.0)
            if self.gas <= 0.0 {
                t.invalidate()
                self.gas = 0.0
                self.maniobraActiva = false
                self.agregarLog("Aterrizado. Motor detenido a 0%.")
            }
        }
    }

    // 4. CORTE TOTAL DE EMERGENCIA (STOP)
    func paradaTotalEmergencia() {
        maniobraActiva = false
        gas = 0.0
        pitch = 127.0
        yaw = 127.0
        // Enviar ráfaga inmediata de parada
        let stopBytes = generarBytesWeccan(gasPorcentaje: 0, pitchVal: 127, yawVal: 127, trimVal: trim, luzVal: luces, matchCanal: match)
        for _ in 0..<10 {
            _ = escribirBytes(stopBytes)
        }
        agregarLog("🛑 PARADA DE EMERGENCIA: Motor cortado a 0%.")
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .errorOccurred:
            DispatchQueue.main.async { self.agregarLog("STREAM: Error de enlace.") }
        case .endEncountered:
            DispatchQueue.main.async {
                self.agregarLog("STREAM: Conexión cerrada.")
                self.cerrarSesion()
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

// MARK: - Interfaz de Usuario SwiftUI
struct ContentView: View {
    @StateObject private var pilot = HeliPilot()

    var body: some View {
        TabView {
            cabinaTab.tabItem {
                Label("Cabina", systemImage: "airplane.circle.fill")
            }

            diagnosticoTab.tabItem {
                Label("Pruebas", systemImage: "bolt.horizontal.fill")
            }

            consolaTab.tabItem {
                Label("Consola", systemImage: "terminal.fill")
            }
        }
    }

    // =================================================================
    // TAB 1: CABINA DE VUELO
    // =================================================================
    var cabinaTab: some View {
        NavigationView {
            Form {
                // Banner de Conexión y Reconexión
                Section {
                    HStack {
                        Circle().fill(pilot.conectado ? Color.green : Color.red).frame(width: 14, height: 14)
                        VStack(alignment: .leading) {
                            Text(pilot.conectado ? "CONECTADO: \(pilot.nombreDispositivo)" : "🔴 HELICÓPTERO DESCONECTADO").bold()
                            Text(pilot.conectado ? "Canal: \(nombreCanal(pilot.match)) · 20Hz Activo" : "Enciende el heli o pulsa Vincular").font(.caption2).foregroundColor(.secondary)
                        }
                        Spacer()
                        Text("\(pilot.framesEnviados) tx").font(.caption).foregroundColor(.secondary)
                    }

                    if !pilot.conectado {
                        Button(action: { pilot.abrirSelectorBluetoothMFi() }) {
                            HStack {
                                Spacer()
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                Text("📲 VINCULAR / RECONECTAR BLUETOOTH").bold()
                                Spacer()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                    }
                }

                // Selector de Canal de Color (A=Rojo, B=Verde, C=Azul)
                Section("Sincronización de Canal / Color de Luz") {
                    Picker("Canal", selection: $pilot.match) {
                        Text("🔴 A (Rojo)").tag(0)
                        Text("🟢 B (Verde)").tag(1)
                        Text("🔵 C (Azul - ÉXITO)").tag(2)
                    }
                    .pickerStyle(.segmented)
                }

                // Control del Acelerador Principal
                Section(header: Text("ACELERADOR DE VUELO (GAS)").bold()) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("POTENCIA REAL").bold()
                            Spacer()
                            Text("\(Int(pilot.gas))%")
                                .font(.title)
                                .bold()
                                .foregroundColor(pilot.gas > 0 ? (pilot.gas > 60 ? .red : .green) : .secondary)
                        }

                        Slider(value: $pilot.gas, in: 0...100, step: 1)
                            .tint(pilot.gas > 0 ? .green : .gray)
                            .disabled(pilot.maniobraActiva)
                    }

                    // Botones de Despegue y Aterrizaje
                    HStack(spacing: 12) {
                        Button(action: { pilot.despegueSuave() }) {
                            HStack {
                                Spacer()
                                Image(systemName: "arrow.up.circle.fill")
                                Text("🛫 DESPEGAR (56%)").bold()
                                Spacer()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .disabled(pilot.maniobraActiva || !pilot.conectado)

                        Button(action: { pilot.aterrizarSuave() }) {
                            HStack {
                                Spacer()
                                Image(systemName: "arrow.down.circle.fill")
                                Text("🛬 ATERRIZAR").bold()
                                Spacer()
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(.blue)
                        .disabled(pilot.gas == 0 || pilot.maniobraActiva)
                    }
                    .padding(.vertical, 4)
                }

                // Botón de Prueba Directa de Vuelo (La ráfaga ganadora de Build 16)
                Section {
                    Button(action: { pilot.ejecutarTestVuelo2Segundos(potencia: 75.0) }) {
                        HStack {
                            Spacer()
                            Image(systemName: "flame.fill").foregroundColor(.yellow)
                            Text("⚡ PROBAR VUELO 2s (GAS 75% CONTROLADO)").bold()
                            Spacer()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(pilot.maniobraActiva || !pilot.conectado)
                }

                // Mandos de Dirección y Estabilidad
                Section(header: Text("DIRECCIÓN (PITCH / YAW / TRIM)").bold()) {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("PITCH (Inclinación Adelante/Atrás)").bold()
                            Spacer()
                            Text("\(Int(pilot.pitch))").font(.caption)
                        }
                        Slider(value: $pilot.pitch, in: 0...255, step: 1)
                    }

                    VStack(alignment: .leading) {
                        HStack {
                            Text("YAW (Giro Izquierda/Derecha)").bold()
                            Spacer()
                            Text("\(Int(pilot.yaw))").font(.caption)
                        }
                        Slider(value: $pilot.yaw, in: 0...255, step: 1)
                    }

                    HStack {
                        Picker("Trim", selection: $pilot.trim) {
                            ForEach(0..<33) { Text("\($0)").tag($0) }
                        }
                        .pickerStyle(.menu)

                        Spacer()

                        Toggle("Faros", isOn: $pilot.luces).tint(.yellow)
                    }

                    Button("🎯 Centrar Dirección (Pitch=127, Yaw=127, Trim=16)") {
                        pilot.pitch = 127.0
                        pilot.yaw = 127.0
                        pilot.trim = 16
                    }
                    .font(.footnote)
                }

                // Botón Gigante de Parada de Emergencia
                Section {
                    Button(action: { pilot.paradaTotalEmergencia() }) {
                        HStack {
                            Spacer()
                            Image(systemName: "stop.circle.fill").font(.title3)
                            Text("CORTE TOTAL DE MOTOR (STOP)").font(.headline).bold()
                            Spacer()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }

                // Trama en tiempo real
                Section {
                    HStack {
                        Text("TRAMA EN VIVO:")
                            .font(.caption2).foregroundColor(.secondary)
                        Spacer()
                        Text(pilot.ultimaTramaHex.isEmpty ? "--" : pilot.ultimaTramaHex)
                            .font(.system(.footnote, design: .monospaced))
                            .bold()
                            .foregroundColor(.blue)
                    }
                }
            }
            .navigationTitle("BluHeli Pilot")
        }
    }

    // =================================================================
    // TAB 2: PRUEBAS DE POTENCIA
    // =================================================================
    var diagnosticoTab: some View {
        NavigationView {
            Form {
                Section("Pulsos de Vuelo Rápido (Sujeta el heli)") {
                    Button("⚡ Pulso Gas al 45% (Sustentación mínima - 2s)") {
                        pilot.ejecutarTestVuelo2Segundos(potencia: 45.0)
                    }
                    Button("⚡ Pulso Gas al 65% (Vuelo medio - 2s)") {
                        pilot.ejecutarTestVuelo2Segundos(potencia: 65.0)
                    }
                    Button("⚡ Pulso Gas al 80% (Vuelo potente - 2s)") {
                        pilot.ejecutarTestVuelo2Segundos(potencia: 80.0)
                    }
                }

                Section("Herramientas de Conexión") {
                    Button("📲 Abrir Selector Bluetooth MFi de Apple") {
                        pilot.abrirSelectorBluetoothMFi()
                    }
                    Button("🔄 Reconectar Automático") {
                        pilot.buscarYConectarAuto()
                    }
                }
            }
            .navigationTitle("Pruebas")
        }
    }

    // =================================================================
    // TAB 3: CONSOLA
    // =================================================================
    var consolaTab: some View {
        NavigationView {
            Form {
                Section("Registro en Vivo") {
                    TextEditor(text: $pilot.log)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 350)
                    HStack {
                        Button("Copiar Registro") {
                            UIPasteboard.general.string = pilot.log
                            pilot.agregarLog("Copiado al portapapeles.")
                        }
                        Spacer()
                        Button("Limpiar") { pilot.log = "" }.foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Consola")
        }
    }

    func nombreCanal(_ m: Int) -> String {
        switch m {
        case 0: return "Rojo (A)"
        case 1: return "Verde (B)"
        case 2: return "Azul (C)"
        default: return "m\(m)"
        }
    }
}

@main
struct BluHeliApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
