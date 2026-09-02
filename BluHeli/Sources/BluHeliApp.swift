import SwiftUI
import ExternalAccessory
import UIKit

// =====================================================================
// BLU-TECH HELI MASTER v6 — CALIBRACIÓN DINÁMICA DE TRAMAS & ROTORES
// =====================================================================

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
        
        timerAutoConnect = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self = self, !self.conectado else { return }
            self.buscarYConectarAuto()
        }
    }

    deinit {
        timerAutoConnect?.invalidate()
    }

    @objc private func accessoryConnected(_ notification: Notification) {
        agregarLog("NOTIF iOS: Accesorio Bluetooth MFi detectado.")
        buscarYConectarAuto()
    }

    @objc private func accessoryDisconnected(_ notification: Notification) {
        agregarLog("NOTIF iOS: Accesorio desconectado.")
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
        agregarLog("Abriendo EASession con \(acc.name) [\(proto)]...")
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
            DispatchQueue.main.async { self.agregarLog("STREAM: Error de comunicación.") }
        case .endEncountered:
            DispatchQueue.main.async {
                self.agregarLog("STREAM: Enlace cerrado por el helicóptero.")
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

    // Mandos de vuelo
    @State private var gas: Double = 64
    @State private var pitch: Double = 127
    @State private var yaw: Double = 127
    @State private var trim: Int = 10
    @State private var matchVal: Int = 1
    @State private var luces = true
    @State private var capSeguro = false
    @State private var modoTramaIdx = 0
    @State private var transmitiendo = true
    @State private var testEnCurso = false

    let nombresModos = [
        "1. Bitmask Oficial (Byte 0: Trim/Luz, Byte 3: Gas, Byte 4: 'x')",
        "2. Header Primero (Byte 0: 'x', Byte 1: Gas, Byte 4: Trim/Luz)",
        "3. Invertido (Byte 0: 'x', Byte 1: Trim/Luz, Byte 4: Gas)",
        "4. Potencia Alta (0..255 en Byte 1, Header 0x78)"
    ]

    func construirTrama(gasVal: Int, pitchVal: Int, yawVal: Int, trimVal: Int, luzVal: Bool, match: Int, modo: Int) -> [UInt8] {
        let h = UInt8(0x78 | ((match & 3) << 6))
        let g = UInt8(Swift.max(0, Swift.min(255, gasVal)))
        let p = UInt8(Swift.max(0, Swift.min(255, pitchVal)))
        let y = UInt8(Swift.max(0, Swift.min(255, yawVal)))
        let l = UInt8(luzVal ? 7 : 3)
        let lt = UInt8(((l & 0x07) << 5) | (UInt8(trimVal) & 0x1F))

        switch modo {
        case 0:
            // Bitmask original de protocalData.plist (Little Endian): [LT, YAW, PITCH, ROTOR, HEADER]
            return [lt, y, p, g, h]
        case 1:
            // Big Endian: [HEADER, ROTOR, PITCH, YAW, LT]
            return [h, g, p, y, lt]
        case 2:
            // Layout alternativo (similar al coche): [HEADER, LT, YAW, PITCH, ROTOR]
            return [h, lt, y, p, g]
        case 3:
            // Potencia directa escalada: [HEADER, g, p, y, lt]
            return [h, UInt8(Swift.min(255, gasVal * 2)), p, y, lt]
        default:
            return [lt, y, p, g, h]
        }
    }

    var tramaActual: [UInt8] {
        let g = capSeguro ? Swift.min(Int(gas), 80) : Int(gas)
        return construirTrama(gasVal: g, pitchVal: Int(pitch), yawVal: Int(yaw),
                              trimVal: trim, luzVal: luces, match: matchVal, modo: modoTramaIdx)
    }

    var body: some View {
        TabView {
            mandoTab.tabItem { Label("Mando", systemImage: "gamecontroller.fill") }
            testsTab.tabItem { Label("Tests", systemImage: "bolt.horizontal.fill") }
            logTab.tabItem { Label("Consola", systemImage: "terminal.fill") }
        }
        .onAppear {
            mgr.agregarLog("Blu-Tech Heli Master v6 Listo.")
            mgr.buscarYConectarAuto()
            iniciarBucleTransmision()
        }
    }

    // ---------- TAB 1: MANDO ----------
    var mandoTab: some View {
        NavigationView {
            Form {
                Section("Estado de Conexión") {
                    HStack {
                        Circle().fill(mgr.conectado ? Color.green : Color.red).frame(width: 14, height: 14)
                        VStack(alignment: .leading) {
                            Text(mgr.conectado ? "CONECTADO: \(mgr.nombreDispositivo)" : "BUSCANDO HELICÓPTERO...").bold()
                            if mgr.conectado {
                                Text("Protocolo: \(mgr.protoActivo)").font(.caption2).foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        Text("\(mgr.framesEnviados) tramas").font(.caption).foregroundColor(.secondary)
                    }
                }

                Section("Orden de Trama (Byte Packing)") {
                    Picker("Modo Trama", selection: $modoTramaIdx) {
                        ForEach(0..<nombresModos.count, id: \.self) { i in
                            Text(nombresModos[i]).tag(i)
                        }
                    }
                }

                Section("Controles de Vuelo") {
                    Toggle("🛡 Modo Seguro (Gas máx 80)", isOn: $capSeguro).tint(.orange)

                    VStack(alignment: .leading) {
                        HStack {
                            Text("GAS (Acelerador)").bold()
                            Spacer()
                            Text("\(Int(capSeguro ? Swift.min(gas, 80) : gas))")
                                .font(.headline)
                                .foregroundColor(gas > 64 ? .orange : .green)
                        }
                        Slider(value: $gas, in: 0...128, step: 1)
                    }

                    VStack(alignment: .leading) {
                        HStack {
                            Text("PITCH (Adelante/Atrás)").bold()
                            Spacer()
                            Text("\(Int(pitch))").font(.subheadline)
                        }
                        Slider(value: $pitch, in: 0...255, step: 1)
                    }

                    VStack(alignment: .leading) {
                        HStack {
                            Text("YAW (Giro de Cola)").bold()
                            Spacer()
                            Text("\(Int(yaw))").font(.subheadline)
                        }
                        Slider(value: $yaw, in: 0...255, step: 1)
                    }

                    HStack {
                        Picker("Trim", selection: $trim) {
                            ForEach(0..<21) { Text("\($0)").tag($0) }
                        }.pickerStyle(.menu)

                        Picker("Match", selection: $matchVal) {
                            ForEach(0..<4) { Text("m\($0)").tag($0) }
                        }.pickerStyle(.menu)

                        Toggle("Luces", isOn: $luces).tint(.yellow)
                    }

                    HStack {
                        Button("🛑 STOP") {
                            gas = 0
                            pitch = 127
                            yaw = 127
                            _ = mgr.enviarTrama(tramaActual)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)

                        Spacer()

                        Text(tramaActual.map { String(format: "%02X", $0) }.joined(separator: " "))
                            .font(.system(.footnote, design: .monospaced))
                            .bold()
                            .foregroundColor(.blue)
                    }
                }
            }
            .navigationTitle("Blu-Tech Heli v6")
        }
    }

    // ---------- TAB 2: TESTS ----------
    var testsTab: some View {
        NavigationView {
            Form {
                Section("Calibración Definitiva de Motores") {
                    Button(action: { ejecutarSuperTestRotores() }) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "flame.fill").foregroundColor(.orange)
                                Text("🔥 SUPER TEST: BARRIDO DE 4 MODOS (GAS 100)").bold()
                            }
                            Text("Prueba los 4 formatos de trama (2 segundos cada uno) con potencia real.").font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .disabled(testEnCurso)

                    Button("⚡ Pulso Gas Modo 1 (Oficial 0..128 - Gas 95)") { probarModoIndividual(0, gas: 95) }
                    Button("⚡ Pulso Gas Modo 2 (Header Primero - Gas 95)") { probarModoIndividual(1, gas: 95) }
                    Button("⚡ Pulso Gas Modo 3 (Invertido - Gas 95)") { probarModoIndividual(2, gas: 95) }
                    Button("⚡ Pulso Gas Modo 4 (Escalado 0..255)") { probarModoIndividual(3, gas: 95) }
                    Button("💡 Test Luces x3") { testLuces() }
                }
            }
            .navigationTitle("Tests y Calibración")
        }
    }

    // ---------- TAB 3: LOG ----------
    var logTab: some View {
        NavigationView {
            Form {
                Section("Consola") {
                    TextEditor(text: $mgr.log)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 350)
                    HStack {
                        Button("Copiar Log") {
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

    func iniciarBucleTransmision() {
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            if mgr.conectado && transmitiendo && !testEnCurso {
                _ = mgr.enviarTrama(tramaActual)
            }
        }
    }

    func probarModoIndividual(_ m: Int, gas: Int) {
        testEnCurso = true
        modoTramaIdx = m
        mgr.agregarLog("PROBANDO MODO \(m+1) con Gas=\(gas) por 2.5 segundos...")
        var n = 0
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { t in
            n += 1
            let pkt = construirTrama(gasVal: gas, pitchVal: 127, yawVal: 127, trimVal: 10, luzVal: true, match: matchVal, modo: m)
            _ = mgr.enviarTrama(pkt)
            if n >= 50 {
                t.invalidate()
                let stopPkt = construirTrama(gasVal: 0, pitchVal: 127, yawVal: 127, trimVal: 10, luzVal: true, match: matchVal, modo: m)
                _ = mgr.enviarTrama(stopPkt)
                testEnCurso = false
                mgr.agregarLog("Fin de prueba Modo \(m+1).")
            }
        }
    }

    func ejecutarSuperTestRotores() {
        testEnCurso = true
        mgr.agregarLog("=== INICIANDO SUPER BARRIDO DE 4 MODOS ===")
        mgr.agregarLog("¡SUJETA EL HELICÓPTERO EN LA MANO!")

        var modoActual = 0
        Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { t in
            if modoActual > 3 {
                t.invalidate()
                testEnCurso = false
                mgr.agregarLog("=== SUPER BARRIDO COMPLETADO ===")
                return
            }

            mgr.agregarLog(">>> PROBANDO MODO \(modoActual + 1) (GAS 100)... <<<")
            self.modoTramaIdx = modoActual
            
            var n = 0
            Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { tt in
                n += 1
                let pkt = self.construirTrama(gasVal: 100, pitchVal: 127, yawVal: 127, trimVal: 10, luzVal: true, match: self.matchVal, modo: modoActual)
                _ = self.mgr.enviarTrama(pkt)
                if n >= 40 {
                    tt.invalidate()
                    let stopPkt = self.construirTrama(gasVal: 0, pitchVal: 127, yawVal: 127, trimVal: 10, luzVal: true, match: self.matchVal, modo: modoActual)
                    _ = self.mgr.enviarTrama(stopPkt)
                }
            }
            modoActual += 1
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
