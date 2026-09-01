import SwiftUI
import ExternalAccessory
import UIKit

// BluHeli v3 — MANDO UNIVERSAL Silverlit/WeCCAN por ExternalAccessory (MFi)
// -----------------------------------------------------------------------
// · 5 perfiles de protocolo REALES extraidos de los config.xml oficiales
//   (APK Silverlit firmada): Helicopter APPS_airplane, BTFerrari APPS_Car,
//   WeCCAN i737, i787 y CHP.
// · Editor de XML: pegas el config.xml de cualquier otro juguete y la app
//   lo parsea (mismo formato que usa Silverlit). Mando universal de verdad.
// · Suite de pruebas por perfil: ping neutro, pulso de gas, luces, barrido
//   de match... para descubrir que canal responde.
// · Log completo con copiar/compartir para depurar fuera del telefono.

// MARK: - Modelo de perfil de protocolo

struct ByteField {
    let desc: String
    let index: Int
    let shift: Int
    let mask: UInt8      // bits que ocupa el campo dentro de su byte
    let max: Int
    let mid: Int
}

struct ProtoProfile: Identifiable {
    let id = UUID()
    let name: String
    let byteTotal: Int
    let headerByte: UInt8?      // byte 0 fijo (ej 'x' = 0x78), nil si no hay
    let reverse: Bool
    let fields: [ByteField]

    func field(contiene: String) -> ByteField? {
        fields.first { $0.desc.lowercased().contains(contiene) }
    }

    /// Construye la trama. valores: desc -> valor numerico ya en rango propio del campo.
    func build(gas: Int? = nil, pitch: Int? = nil, yaw: Int? = nil,
               trim: Int? = nil, luz: Int? = nil, match: Int? = nil,
               extra: [String: Int] = [:]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: byteTotal)
        if let h = headerByte { out[0] = h }
        // mapa canal -> valor
        var vals: [(String, Int)] = []
        if let v = gas { vals.append(("rotor", v)) }
        if let v = pitch { vals.append(("pitch", v)) }
        if let v = yaw { vals.append(("yaw", v)) }
        if let v = trim { vals.append(("trim", v)) }
        if let v = luz { vals.append(("light", v)) }
        if let v = match { vals.append(("match", v)) }
        for (k, v) in extra { vals.append((k, v)) }

        for (canal, valor) in vals {
            guard let f = field(contiene: canal) else { continue }
            let clamped = max(0, min(f.max, valor))
            let bits = (UInt8(clamped) << f.shift) & f.mask
            out[f.index] |= bits
        }
        return out
    }

    var resumen: String {
        "\(byteTotal) bytes · header: \(headerByte.map { "'\(Character(UnicodeScalar($0)))' (0x\(String($0, radix: 16)))" } ?? "none") · campos: \(fields.map(\.desc).joined(separator: ", "))"
    }
}

// MARK: - Perfiles embebidos (datos reales de los XML oficiales)

enum Perfiles {
    static let silverlitHeli = ProtoProfile(
        name: "Silverlit Helicopter (APPS_airplane) — TU BSH-A",
        byteTotal: 5, headerByte: 0x78, reverse: false,
        fields: [
            ByteField(desc: "matchByte", index: 0, shift: 6, mask: 0xC0, max: 3, mid: 1),
            ByteField(desc: "rotorByte", index: 1, shift: 0, mask: 0x7F, max: 128, mid: 64),
            ByteField(desc: "pitchByte", index: 2, shift: 0, mask: 0xFF, max: 255, mid: 127),
            ByteField(desc: "yawByte", index: 3, shift: 0, mask: 0xFF, max: 255, mid: 127),
            ByteField(desc: "trimerByte", index: 4, shift: 0, mask: 0x0F, max: 15, mid: 8),
            ByteField(desc: "lightByte", index: 4, shift: 5, mask: 0xE0, max: 7, mid: 3),
        ])

    static let btferrari = ProtoProfile(
        name: "Silverlit BTFerrari (APPS_Car) — el de la app del coche",
        byteTotal: 5, headerByte: 0x72, reverse: true,   // 'r'
        fields: [
            ByteField(desc: "matchByte", index: 4, shift: 6, mask: 0xC0, max: 3, mid: 1),
            ByteField(desc: "rotorByte", index: 3, shift: 0, mask: 0xFF, max: 255, mid: 127),
            ByteField(desc: "pitchByte", index: 2, shift: 0, mask: 0xFF, max: 255, mid: 127),
            ByteField(desc: "yawByte", index: 1, shift: 0, mask: 0xFF, max: 255, mid: 127),
            ByteField(desc: "trimerByte", index: 0, shift: 0, mask: 0x0F, max: 15, mid: 7),
            ByteField(desc: "lightByte", index: 0, shift: 4, mask: 0xF0, max: 15, mid: 7),
        ])

    static let weccanI737 = ProtoProfile(
        name: "WeCCAN i737 (6B, header '0x')",
        byteTotal: 6, headerByte: nil, reverse: true,
        fields: [
            ByteField(desc: "unknownByte", index: 0, shift: 0, mask: 0x0F, max: 15, mid: 8),
            ByteField(desc: "fightByte", index: 0, shift: 4, mask: 0xF0, max: 15, mid: 8),
            ByteField(desc: "trimerByte", index: 1, shift: 0, mask: 0xFF, max: 32, mid: 16),
            ByteField(desc: "yawByte", index: 2, shift: 0, mask: 0xFF, max: 255, mid: 127),
            ByteField(desc: "pitchByte", index: 3, shift: 0, mask: 0xFF, max: 255, mid: 127),
            ByteField(desc: "rotorByte", index: 4, shift: 0, mask: 0xFF, max: 255, mid: 127),
            ByteField(desc: "trimerFlagByte", index: 5, shift: 0, mask: 0x03, max: 3, mid: 2),
            ByteField(desc: "yawFlagByte", index: 5, shift: 2, mask: 0x0C, max: 3, mid: 2),
            ByteField(desc: "pitchFlagByte", index: 5, shift: 4, mask: 0x30, max: 3, mid: 2),
            ByteField(desc: "matchByte", index: 5, shift: 6, mask: 0xC0, max: 3, mid: 2),
        ])

    static let weccanI787 = ProtoProfile(
        name: "WeCCAN i787 (6B, camara)",
        byteTotal: 6, headerByte: nil, reverse: true,
        fields: [
            ByteField(desc: "trimmer", index: 1, shift: 0, mask: 0xFF, max: 255, mid: 127),
            ByteField(desc: "yawByte", index: 2, shift: 0, mask: 0xFF, max: 255, mid: 127),
            ByteField(desc: "pitchByte", index: 3, shift: 0, mask: 0xFF, max: 255, mid: 127),
            ByteField(desc: "rotorByte", index: 4, shift: 0, mask: 0xFF, max: 255, mid: 127),
            ByteField(desc: "matchByte", index: 5, shift: 6, mask: 0xC0, max: 3, mid: 0),
        ])

    static let weccanCHP = ProtoProfile(
        name: "WeCCAN CHP (6B, luz en byte 0)",
        byteTotal: 6, headerByte: nil, reverse: true,
        fields: [
            ByteField(desc: "ch4Yaw", index: 0, shift: 0, mask: 0x0F, max: 15, mid: 0),
            ByteField(desc: "lightByte", index: 0, shift: 4, mask: 0xF0, max: 15, mid: 0),
            ByteField(desc: "trimmer", index: 1, shift: 0, mask: 0xFF, max: 255, mid: 127),
            ByteField(desc: "yawByte", index: 2, shift: 0, mask: 0xFF, max: 255, mid: 127),
            ByteField(desc: "pitchByte", index: 3, shift: 0, mask: 0xFF, max: 255, mid: 127),
            ByteField(desc: "rotorByte", index: 4, shift: 0, mask: 0xFF, max: 255, mid: 127),
            ByteField(desc: "matchByte", index: 5, shift: 6, mask: 0xC0, max: 3, mid: 0),
        ])

    static let todos = [silverlitHeli, btferrari, weccanI737, weccanI787, weccanCHP]
}

// MARK: - Parser del config.xml de Silverlit (para perfiles custom pegados)

final class ConfigXMLParser: NSObject, XMLParserDelegate {
    var perfiles: [ProtoProfile] = []
    private var actual: (name: String, byteTotal: Int, header: String?, reverse: Bool, fields: [ByteField])?
    private var campo: (desc: String, index: Int, begin: Int, end: Int, max: Int, mid: Int, min: Int, shift: Int)?
    private var texto = ""
    private var seccion: String = ""

    func parse(_ data: Data) -> [ProtoProfile] {
        let p = XMLParser(data: data)
        p.delegate = self
        p.parse()
        return perfiles
    }

    func parser(_ parser: XMLParser, didStartElement el: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        texto = ""
        if el == "byte" { campo = ("", 0, 0, 7, 0, 0, 0, 0) }
    }

    func parser(_ parser: XMLParser, foundCharacters s: String) { texto += s }

    private var limpio: String { texto.trimmingCharacters(in: .whitespacesAndNewlines) }

    func parser(_ parser: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName: String?) {
        switch el {
        case "name": actual?.name = limpio
        case "byteTotal":
            if let n = Int(limpio) {
                if actual == nil { actual = ("?", n, nil, false, []) }
                else { actual!.byteTotal = n }
            }
        case "header":
            if actual != nil { actual!.header = limpio.isEmpty ? nil : limpio }
        case "reverse":
            if actual != nil { actual!.reverse = limpio == "1" }
        case "desc":
            if campo != nil { campo!.desc = limpio } else if actual == nil { seccion = limpio }
        case "index": campo?.index = Int(limpio) ?? 0
        case "begin": campo?.begin = Int(limpio) ?? 0
        case "end": campo?.end = Int(limpio) ?? 7
        case "max": campo?.max = Int(limpio) ?? 0
        case "mid": campo?.mid = Int(limpio) ?? 0
        case "min": campo?.min = Int(limpio) ?? 0
        case "shift": campo?.shift = Int(limpio) ?? 0
        case "byte":
            if let c = campo, let a = actual {
                let ancho = max(1, c.begin - c.end + 1)
                let mask: UInt8 = ancho >= 8 ? 0xFF : UInt8((1 << ancho) - 1) << c.end
                let f = ByteField(desc: c.desc, index: c.index, shift: c.shift, mask: mask, max: c.max, mid: c.mid)
                actual!.fields.append(f)
            }
            campo = nil
        case "model":
            if let a = actual, !a.fields.isEmpty {
                let headerByte = a.header.flatMap { $0.isEmpty ? nil : $0.utf8.first }
                perfiles.append(ProtoProfile(name: a.name, byteTotal: a.byteTotal,
                                             headerByte: headerByte, reverse: a.reverse, fields: a.fields))
            }
            actual = nil
        default: break
        }
    }
}

// MARK: - Gestor EA

final class HeliManager: NSObject, ObservableObject, StreamDelegate {
    @Published var accesorios: [AccInfo] = []
    @Published var conectado = false
    @Published var protoActivo = ""
    @Published var log = ""
    @Published var framesEnviados = 0

    struct AccInfo: Identifiable, Hashable {
        let id: Int
        let nombre: String
        let fabricante: String
        let protocolos: [String]
    }

    private var session: EASession?

    func escanear(loguear: (String) -> Void) -> [AccInfo] {
        EAAccessoryManager.shared().registerForLocalNotifications()
        let lista = EAAccessoryManager.shared().connectedAccessories.compactMap { acc -> AccInfo? in
            AccInfo(id: acc.connectionID, nombre: acc.name, fabricante: acc.manufacturer,
                    protocolos: acc.protocolStrings.sorted())
        }
        accesorios = lista
        if lista.isEmpty {
            loguear("SCAN: sin accesorios MFi conectados")
        } else {
            for a in lista {
                loguear("SCAN: \(a.nombre) [\(a.fabricante)] protocols: \(a.protocolos.joined(separator: " | "))")
            }
        }
        return lista
    }

    func conectar(acc: AccInfo, proto: String, loguear: @escaping (String) -> Void) -> Bool {
        cerrar(loguear: loguear)
        guard let ea = EAAccessoryManager.shared().connectedAccessories.first(where: { $0.connectionID == acc.id }) else {
            loguear("CONN: X el accesorio ya no esta")
            return false
        }
        guard let ses = EASession(accessory: ea, forProtocol: proto) else {
            loguear("CONN: X iOS rechazo EASession para '\(proto)'")
            return false
        }
        session = ses
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
        loguear("CONN: OK sesion abierta [\(proto)]")
        return true
    }

    func cerrar(loguear: (String) -> Void = { _ in }) {
        if let ses = session {
            ses.inputStream?.close(); ses.outputStream?.close()
            ses.inputStream?.remove(from: .main, forMode: .default)
            ses.outputStream?.remove(from: .main, forMode: .default)
            loguear("CONN: sesion cerrada")
        }
        session = nil
        conectado = false
        framesEnviados = 0
    }

    func enviar(_ bytes: [UInt8], loguear: @escaping (String) -> Void) -> Bool {
        guard let out = session?.outputStream, out.hasSpaceAvailable else {
            loguear("TX X sin espacio en el stream (¿conexion muerta?)")
            return false
        }
        let ok = out.write(bytes, maxLength: bytes.count) == bytes.count
        if ok {
            framesEnviados += 1
        } else {
            loguear("TX X write fallo")
        }
        return ok
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .errorOccurred: anotar("STREAM: error")
        case .endEncountered: anotar("STREAM: el otro extremo cerro"); conectado = false
        case .hasBytesAvailable:
            if let inp = aStream as? InputStream {
                var buf = [UInt8](repeating: 0, count: 64)
                let n = inp.read(&buf, maxLength: 64)
                if n > 0 { anotar("RX: " + buf.prefix(n).map { String(format: "%02X", $0) }.joined(separator: " ")) }
            }
        default: break
        }
    }

    private func anotar(_ s: String) {
        DispatchQueue.main.async { self.agregarLog(s) }
    }

    func agregarLog(_ s: String) {
        let df = DateFormatter(); df.dateFormat = "HH:mm:ss"
        log = "[\(df.string(from: Date()))] \(s)\n" + log
        if log.count > 12000 { log = String(log.prefix(12000)) }
    }
}

// MARK: - Vista principal

struct ContentView: View {
    @StateObject private var mgr = HeliManager()

    // conexion
    @State private var accSel: HeliManager.AccInfo?
    @State private var protoSel = ""
    // perfil
    @State private var perfiles: [ProtoProfile] = Perfiles.todos
    @State private var perfilIdx = 0
    @State private var xmlEditor = ""
    // mando
    @State private var gas: Double = 64
    @State private var pitch: Double = 127
    @State private var yaw: Double = 127
    @State private var trim: Int = 8
    @State private var matchVal: Int = 1
    @State private var luces = false
    @State private var vivo = false
    @State private var hz = 20.0
    @State private var capSeguro = true
    // test suite
    @State private var testeando = false

    var perfil: ProtoProfile { perfiles[perfilIdx] }

    var tramaActual: [UInt8] {
        var g: Int? = Int(gas)
        if capSeguro { g = min(g ?? 64, 80) }
        return perfil.build(gas: g, pitch: Int(pitch), yaw: Int(yaw),
                            trim: trim, luz: luces ? 4 : nil, match: matchVal)
    }

    var body: some View {
        TabView {
            mandoTab.tabItem { Label("Mando", systemImage: "gamecontroller") }
            protocolosTab.tabItem { Label("Protocolos", systemImage: "square.stack.3d.up") }
            logTab.tabItem { Label("Log", systemImage: "terminal") }
        }
        .onAppear { doLog("APP v3 lista. Enciende el heli y pulsa ESCANEAR.") }
    }

    // ---------- TAB 1: MANDO ----------
    var mandoTab: some View {
        Form {
                Section("Conexion") {
                HStack {
                    Circle().fill(mgr.conectado ? Color.green : Color.red).frame(width: 10, height: 10)
                    Text(mgr.conectado ? "Conectado [\(mgr.protoActivo)]" : "Desconectado").font(.footnote)
                    Spacer()
                    Text("\(mgr.framesEnviados) tramas").font(.caption2).foregroundColor(.secondary)
                }
                Button("Escanear accesorios MFi") {
                    let lista = mgr.escanear(loguear: doLog)
                    if let primero = lista.first {
                        accSel = primero
                        protoSel = primero.protocolos.first ?? ""
                    }
                }
                if !mgr.accesorios.isEmpty {
                    Picker("Accesorio", selection: $accSel) {
                        ForEach(mgr.accesorios, id: \.self) { Text($0.nombre).tag($0 as HeliManager.AccInfo?) }
                    }
                    Picker("Protocolo MFi", selection: $protoSel) {
                        ForEach(accSel?.protocolos ?? [], id: \.self) { Text($0).tag($0) }
                    }
                    Button("Conectar") {
                        if let a = accSel, !protoSel.isEmpty {
                            _ = mgr.conectar(acc: a, proto: protoSel, loguear: doLog)
                        } else { doLog("CONN: elige accesorio y protocolo") }
                    }.disabled(mgr.conectado)
                }
            }

            Section("Perfil de protocolo") {
                Picker("Perfil", selection: $perfilIdx) {
                    ForEach(Array(perfiles.enumerated()), id: \.offset) { i, p in
                        Text(p.name).tag(i)
                    }
                }
                Text(perfil.resumen).font(.caption2).foregroundColor(.secondary)
            }

            Section("Mando (trama en vivo abajo)") {
                Toggle("Modo seguro (gas max 80)", isOn: $capSeguro).tint(.orange)
                VStack(alignment: .leading) {
                    HStack { Text("GAS").bold(); Spacer(); Text("\(Int(capSeguro ? min(gas, 80) : gas))").monospaced() }
                    Slider(value: $gas, in: 64...128, step: 1)
                }
                VStack(alignment: .leading) {
                    HStack { Text("PITCH").bold(); Spacer(); Text("\(Int(pitch))").monospaced() }
                    Slider(value: $pitch, in: 0...255, step: 1)
                }
                VStack(alignment: .leading) {
                    HStack { Text("YAW").bold(); Spacer(); Text("\(Int(yaw))").monospaced() }
                    Slider(value: $yaw, in: 0...255, step: 1)
                }
                HStack {
                    Picker("trim", selection: $trim) { ForEach(0..<16) { Text("\($0)").tag($0) } }.pickerStyle(.menu)
                    Picker("match", selection: $matchVal) { ForEach(0..<4) { Text("m\($0)").tag($0) } }.pickerStyle(.menu)
                    Toggle("Luces", isOn: $luces)
                }
                HStack {
                    Toggle(vivo ? "ENVIANDO" : "Enviar continuo", isOn: $vivo).tint(vivo ? .green : .blue)
                    Picker("", selection: $hz) {
                        Text("10Hz").tag(10.0); Text("20Hz").tag(20.0); Text("50Hz").tag(50.0)
                    }.pickerStyle(.menu)
                }
                HStack {
                    Button("STOP") {
                        gas = 64; pitch = 127; yaw = 127
                        _ = mgr.enviar(perfil.build(gas: 64, pitch: 127, yaw: 127, trim: trim, luz: 3, match: matchVal), loguear: doLog)
                    }.buttonStyle(.borderedProminent).tint(.red)
                    Spacer()
                    Text(tramaActual.map { String(format: "%02X", $0) }.joined(separator: " "))
                        .font(.system(.footnote, design: .monospaced)).foregroundColor(.blue)
                }
            }
        }
        .navigationTitle("BluHeli Universal")
        .onChange(of: vivo) { on in
            guard on else { return }
            Timer.scheduledTimer(withTimeInterval: 1.0 / hz, repeats: true) { t in
                if !vivo { t.invalidate(); return }
                _ = mgr.enviar(tramaActual, loguear: doLog)
            }
        }
    }

    // ---------- TAB 2: PROTOCOLOS ----------
    var protocolosTab: some View {
        Form {
            Section("Perfiles embebidos + custom") {
                Picker("Perfil activo (afecta al Mando)", selection: $perfilIdx) {
                    ForEach(Array(perfiles.enumerated()), id: \.offset) { i, p in Text(p.name).tag(i) }
                }
                ForEach(Array(perfiles.enumerated()), id: \.offset) { i, p in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name).font(.footnote).fontWeight(i == perfilIdx ? .bold : .regular)
                        Text(p.resumen).font(.caption2).foregroundColor(.secondary)
                    }
                }
            }

            Section("Suite de pruebas (heli responde = canal OK)") {
                Button("1. PING neutro (5 tramas)") { pulsarTest { p in p.build(gas: 64, pitch: 127, yaw: 127, trim: 8, luz: 3, match: 1) } }
                Button("2. Pulso GAS +16 (2s)") { pulsarTest(duracion: 2) { p in p.build(gas: 80, pitch: 127, yaw: 127, trim: 8, luz: 3, match: 1) } }
                Button("3. Luces ON/OFF x3") { probarLuces() }
                Button("4. Barrido match 0-3 (1s cada)") { barridoMatch() }
                Button("5. Barrido GAS 64→128 (3s)") { barridoGas() }
                if testeando { ProgressView().padding(2) }
            }

            Section("Mando universal: pegar config.xml de cualquier juguete") {
                Button("Cargar XML pegado (formato Silverlit)") { cargarXML() }
                TextEditor(text: $xmlEditor)
                    .font(.system(.caption2, design: .monospaced))
                    .frame(height: 140)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                Text("Pega aqui un <configs> completo (ej. weccan_protocal.xml) y aparecera como perfil nuevo.").font(.caption2).foregroundColor(.secondary)
            }
        }
    }

    // ---------- TAB 3: LOG ----------
    var logTab: some View {
        Form {
            Section("Log de sesion (auto + lo que pegues)") {
                TextEditor(text: $mgr.log)
                    .font(.system(.caption2, design: .monospaced))
                    .frame(minHeight: 320)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                HStack {
                    Button("Copiar todo") { UIPasteboard.general.string = mgr.log; doLog("LOG copiado al portapapeles") }
                    if #available(iOS 16.0, *) { ShareLink("Compartir", item: mgr.log) }
                    Spacer()
                    Button("Limpiar", role: .destructive) { mgr.log = "" }
                }
                Text("Pega aqui cualquier cosa (hex mios, logs de otros) y dale a Copiar para mandarmelo.").font(.caption2).foregroundColor(.secondary)
            }
        }
    }

    // ---------- helpers de test ----------
    func pulsarTest(duracion: Double = 0.5, trama: @escaping (ProtoProfile) -> [UInt8]) {
        testeando = true
        doLog("TEST: enviando \(Int(duracion * 20)) tramas (20Hz)...")
        var n = 0
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { t in
            n += 1
            _ = mgr.enviar(trama(perfil), loguear: doLog)
            if n >= Int(duracion * 20) { t.invalidate(); testeando = false; doLog("TEST: fin (\(n) tramas)") }
        }
    }

    func probarLuces() {
        testeando = true
        doLog("TEST: luces ON/OFF x3")
        var paso = 0
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { t in
            paso += 1
            let on = paso % 2 == 1
            let luzVal = perfil.field(contiene: "light").map { on ? max(0, $0.mid + 1) : $0.mid } ?? (on ? 4 : 3)
            _ = mgr.enviar(perfil.build(gas: 64, pitch: 127, yaw: 127, luz: luzVal, match: matchVal), loguear: doLog)
            if paso >= 6 { t.invalidate(); testeando = false; doLog("TEST: luces fin") }
        }
    }

    func barridoMatch() {
        testeando = true
        doLog("TEST: barrido match 0,1,2,3 (1s cada)")
        var m = 0
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { t in
            defer { m += 1 }
            if m > 3 { t.invalidate(); testeando = false; doLog("TEST: barrido match fin"); return }
            doLog("TEST: match=\(m)")
            var n = 0
            Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { tt in
                n += 1
                _ = mgr.enviar(perfil.build(gas: 64, pitch: 127, yaw: 127, trim: 8, luz: 3, match: m), loguear: doLog)
                if n >= 20 { tt.invalidate() }
            }
        }
    }

    func barridoGas() {
        testeando = true
        doLog("TEST: barrido gas 64->128 en 3s (HELI EN LA MANO)")
        var n = 0
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { t in
            n += 1
            let g = 64 + min(64, n / 2)
            _ = mgr.enviar(perfil.build(gas: g, pitch: 127, yaw: 127, trim: 8, luz: 3, match: matchVal), loguear: doLog)
            if n >= 60 { t.invalidate(); testeando = false; doLog("TEST: barrido gas fin") }
        }
    }

    func cargarXML() {
        guard let data = xmlEditor.data(using: .utf8) else { doLog("XML: no hay datos"); return }
        let parseados = ConfigXMLParser().parse(data)
        if parseados.isEmpty {
            doLog("XML: 0 perfiles parseados (¿formato incorrecto?)")
        } else {
            perfiles.append(contentsOf: parseados)
            doLog("XML: +\(parseados.count) perfiles (\(parseados.map(\.name).joined(separator: ", ")))")
        }
    }

    func doLog(_ s: String) { mgr.agregarLog(s) }
}

@main
struct BluHeliApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
