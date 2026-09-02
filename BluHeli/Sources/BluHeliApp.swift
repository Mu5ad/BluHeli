import SwiftUI
import ExternalAccessory
import UIKit

// =====================================================================
// BLU-TECH HELI MASTER v7 — SISTEMA DE ARMADO ESC & CONTROL DE VUELO
// =====================================================================

final class HeliManager: NSObject, ObservableObject, StreamDelegate {
    @Published var conectado = false
    @Published var nombreDispositivo = ""
    @Published var protoActivo = ""
    @Published var log = ""
    @Published var framesEnviados = 0
    @Published var armado = false

    private var session: EASession?
    private var timerAutoConnect: Timer?

    override init() {
        super.init()
        EAAccessoryManager.shared().registerForLocalNotifications()
        NotificationCenter.default.addObserver(self, selector: #selector(accessoryConnected(_:)),
                                               name: .EAAccessoryDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(accessoryDisconnected(_:)),
                                               name: .EAAccessoryDidDisconnect, object: nil)

        timerAutoConnect = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self = self, !self.conectado else { return }
            self.buscarYConectarAuto()
        }
    }

    deinit {
        timerAutoConnect?.invalidate()
    }

    @objc private func accessoryConnected(_ notification: Notification) {
        agregarLog("NOTIF iOS: Conectado a Bluetooth MFi.")
        buscarYConectarAuto()
    }

    @objc private func accessoryDisconnected(_ notification: Notification) {
        agregarLog("NOTIF iOS: Desconectado.")
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
        agregarLog("Abriendo enlace con \(acc.name)...")
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
        armado = false
        agregarLog(">>> ¡CONECTADO A \(acc.name)! Iniciando secuencia de armado ESC... <<<")
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
        armado = false
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
            DispatchQueue.main.async { self.agregarLog("STREAM: Error de comunicación.") }
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

    // Mandos de vuelo (0..128 oficial)
    @State private var gas: Double = 0.0      // Cero absoluto para armado seguro del ESC
    @State private var pitch: Double = 127.0
    @State private var yaw: Double = 127.0
    @State private var trim: Int = 10         // Centro 10 de protocalData.plist
    @State private var matchVal: Int = 1      // 0=Rojo, 1=Verde, 2=Azul
    @State private var luces = true
    @State private var armadoManual = false
    @State private var rutinaEnCurso = false

    // Generador de trama oficial Silverlit (protocalData.plist)
    func generarTrama(gasVal: Double, pitchVal: Double, yawVal: Double, trimVal: Int, luzVal: Bool, match: Int) -> [UInt8] {
        let header = UInt8(0x78 | ((match & 3) << 6))
        let g = UInt8(Swift.max(0, Swift.min(128, Int(gasVal))))
        let p = UInt8(Swift.max(0, Swift.min(255, Int(pitchVal))))
        let y = UInt8(Swift.max(0, Swift.min(255, Int(yawVal))))
        let l = UInt8(luzVal ? 7 : 3)
        let lt = UInt8(((l & 0x07) << 5) | (UInt8(trimVal) & 0x1F))
        return [header, g, p, y, lt]
    }

    var tramaActual: [UInt8] {
        generarTrama(gasVal: gas, pitchVal: pitch, yawVal: yaw, trimVal: trim, luzVal: luces, match: matchVal)
    }

    var body: some View {
        TabView {
            mandoTab.tabItem { Label("Mando", systemImage: "airplane") }
            canalesTab.tabItem { Label("Canales & Tests", systemImage: "antenna.radiowaves.left.and.right") }
            logTab.tabItem { Label("Consola", systemImage: "terminal.fill") }
        }
        .onAppear {
            mgr.agregarLog("Blu-Tech Heli Master v7 Iniciado.")
            mgr.buscarYConectarAuto()
            iniciarBucleTransmision()
        }
    }

    // ---------- TAB 1: MANDO DE VUELO ----------
    var mandoTab: some View {
        NavigationView {
            Form {
                Section("Estado de Vuelo") {
                    HStack {
                        Circle().fill(mgr.conectado ? (armadoManual ? Color.green : Color.orange) : Color.red).frame(width: 14, height: 14)
                        VStack(alignment: .leading) {
                            Text(mgr.conectado ? (armadoManual ? "🟢 ARMADO Y LISTO" : "🟡 CONECTADO (Desarmado)") : "🔴 DESCONECTADO").bold()
                            if mgr.conectado {
                                Text("Canal: \(nombreCanal(matchVal)) · \(mgr.protoActivo)").font(.caption2).foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        Text("\(mgr.framesEnviados) tramas").font(.caption).foregroundColor(.secondary)
                    }

                    if mgr.conectado && !armadoManual {
                        Button(action: { armarHelicoptero() }) {
                            HStack {
                                Image(systemName: "lock.open.fill").foregroundColor(.green)
                                Text("ARMAR HELICÓPTERO (Calibrar ESC)").bold()
                            }
                        }
                    }
                }

                Section("Selección Rápida de Canal / Color") {
                    Picker("Canal LED", selection: $matchVal) {
                        Text("🔴 Canal A (LED Rojo)").tag(0)
                        Text("🟢 Canal B (LED Verde)").tag(1)
                        Text("🔵 Canal C (LED Azul)").tag(2)
                    }
                    .pickerStyle(.segmented)
                }

                Section("Acelerador (GAS)") {
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
                        Button("🛫 Despegue Suave (65%)") { despegueSuave() }
                            .buttonStyle(.bordered)
                            .tint(.green)
                            .disabled(!armadoManual || rutinaEnCurso)

                        Spacer()

                        Button("🛬 Aterrizar") { aterrizarSuave() }
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
                            Text("YAW (Giro)").bold()
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

                        Toggle("Faros", isOn: $luces).tint(.yellow)
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
                        Text("TRAMA HEX:")
                            .font(.caption2).foregroundColor(.secondary)
                        Spacer()
                        Text(tramaActual.map { String(format: "%02X", $0) }.joined(separator: " "))
                            .font(.system(.footnote, design: .monospaced))
                            .bold()
                            .foregroundColor(.blue)
                    }
                }
            }
            .navigationTitle("Blu-Tech Heli")
        }
    }

    // ---------- TAB 2: CANALES & TESTS ----------
    var canalesTab: some View {
        NavigationView {
            Form {
                Section("Test de Motores por Canal (Con Armado)") {
                    Button("⚡ Probar Motor en CANAL A (Rojo - Match 0)") { testMotorEnCanal(0) }
                    Button("⚡ Probar Motor en CANAL B (Verde - Match 1)") { testMotorEnCanal(1) }
                    Button("⚡ Probar Motor en CANAL C (Azul - Match 2)") { testMotorEnCanal(2) }
                }

                Section("Luces y Calibración") {
                    Button("💡 Test Parpadeo de Luces (x3)") { testLuces() }
                    Button("🎯 Centrar Mandos (Gas=0, Pitch=127, Yaw=127)") {
                        gas = 0; pitch = 127; yaw = 127; trim = 10
                    }
                }
            }
            .navigationTitle("Canales y Pruebas")
        }
    }

    // ---------- TAB 3: CONSOLA ----------
    var logTab: some View {
        NavigationView {
            Form {
                Section("Registro en Vivo") {
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

    func nombreCanal(_ m: Int) -> String {
        switch m {
        case 0: return "Rojo (A)"
        case 1: return "Verde (B)"
        case 2: return "Azul (C)"
        default: return "m\(m)"
        }
    }

    func iniciarBucleTransmision() {
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            if mgr.conectado && !rutinaEnCurso {
                _ = mgr.enviarTrama(tramaActual)
            }
        }
    }

    func armarHelicoptero() {
        rutinaEnCurso = true
        mgr.agregarLog("ARMANDO ESC: Enviando Gas = 0 (Punto neutro)...")
        gas = 0
        var n = 0
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { t in
            n += 1
            let pkt = self.generarTrama(gasVal: 0, pitchVal: 127, yawVal: 127, trimVal: self.trim, luzVal: true, match: self.matchVal)
            _ = self.mgr.enviarTrama(pkt)
            if n >= 30 { // 1.5s
                t.invalidate()
                self.armadoManual = true
                self.rutinaEnCurso = false
                self.mgr.agregarLog(">>> ¡HELICÓPTERO ARMADO Y LISTO PARA VOLAR! <<<")
            }
        }
    }

    func despegueSuave() {
        rutinaEnCurso = true
        mgr.agregarLog("Iniciando despegue suave progresivo...")
        var paso = 0
        Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { t in
            paso += 1
            self.gas = Swift.min(85.0, Double(paso * 4))
            let pkt = self.generarTrama(gasVal: self.gas, pitchVal: 127, yawVal: 127, trimVal: self.trim, luzVal: true, match: self.matchVal)
            _ = self.mgr.enviarTrama(pkt)
            if self.gas >= 85.0 {
                t.invalidate()
                self.rutinaEnCurso = false
                self.mgr.agregarLog("Despegue completado a 65% de potencia.")
            }
        }
    }

    func aterrizarSuave() {
        rutinaEnCurso = true
        mgr.agregarLog("Aterrizando suavemente...")
        Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { t in
            self.gas = Swift.max(0.0, self.gas - 3.0)
            let pkt = self.generarTrama(gasVal: self.gas, pitchVal: 127, yawVal: 127, trimVal: self.trim, luzVal: true, match: self.matchVal)
            _ = self.mgr.enviarTrama(pkt)
            if self.gas <= 0.0 {
                t.invalidate()
                self.gas = 0.0
                self.rutinaEnCurso = false
                self.mgr.agregarLog("Aterrizaje completado. Motor apagado.")
            }
        }
    }

    func paradaEmergencia() {
        rutinaEnCurso = false
        gas = 0.0
        pitch = 127.0
        yaw = 127.0
        let stopPkt = generarTrama(gasVal: 0, pitchVal: 127, yawVal: 127, trimVal: trim, luzVal: luces, match: matchVal)
        _ = mgr.enviarTrama(stopPkt)
        mgr.agregarLog("🛑 PARADA DE EMERGENCIA EJECUTADA: Gas = 0.")
    }

    func testMotorEnCanal(_ canal: Int) {
        rutinaEnCurso = true
        matchVal = canal
        mgr.agregarLog("=== PROBANDO MOTOR EN CANAL \(nombreCanal(canal)) ===")
        mgr.agregarLog("1. Calibrando ESC a Gas = 0...")

        var tick = 0
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { t in
            tick += 1
            if tick <= 30 {
                // Fase 1: Gas = 0 (1.5s)
                let pkt = self.generarTrama(gasVal: 0, pitchVal: 127, yawVal: 127, trimVal: 10, luzVal: true, match: canal)
                _ = self.mgr.enviarTrama(pkt)
            } else if tick <= 80 {
                // Fase 2: Gas = 90 (2.5s) - Potencia real
                if tick == 31 { self.mgr.agregarLog("2. ¡POTENCIA DE MOTOR (Gas 90)!...") }
                let pkt = self.generarTrama(gasVal: 90, pitchVal: 127, yawVal: 127, trimVal: 10, luzVal: true, match: canal)
                _ = self.mgr.enviarTrama(pkt)
            } else {
                // Fase 3: Detener
                t.invalidate()
                let stopPkt = self.generarTrama(gasVal: 0, pitchVal: 127, yawVal: 127, trimVal: 10, luzVal: true, match: canal)
                _ = self.mgr.enviarTrama(stopPkt)
                self.rutinaEnCurso = false
                self.mgr.agregarLog("Fin de prueba de motor en Canal \(self.nombreCanal(canal)).")
            }
        }
    }

    func testLuces() {
        mgr.agregarLog("TEST: Parpadeo de luces x3...")
        var paso = 0
        Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { t in
            paso += 1
            self.luces.toggle()
            if paso >= 6 {
                t.invalidate()
                self.luces = true
                self.mgr.agregarLog("TEST: Fin de test de luces.")
            }
        }
    }
}

@main
struct BluHeliApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
