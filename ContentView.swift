import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

struct ContentView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> CapViewController {
        CapViewController()
    }

    func updateUIViewController(_ controller: CapViewController, context: Context) {}
}

final class CapViewController: UIViewController, WKUIDelegate, WKNavigationDelegate,
    UIDocumentPickerDelegate, WKScriptMessageHandler {

    private var webView: WKWebView?
    private var exportURL: URL?
    private let daysKey = "cap.days"
    private let profileKey = "cap.profile"

    override func viewDidLoad() {
        super.viewDidLoad()

        let configuration = WKWebViewConfiguration()
        let content = configuration.userContentController
        let defaults = UserDefaults.standard
        let saved = [defaults.string(forKey: daysKey) ?? "{}",
                     defaults.string(forKey: profileKey) ?? "{}"]
        let encoded = (try? JSONEncoder().encode(saved).base64EncodedString()) ?? "WyJ7fSIsInt9Il0="
        let bridge = """
        (() => {
          const bytes = Uint8Array.from(atob('\(encoded)'), character => character.charCodeAt(0));
          let [days, profile] = JSON.parse(new TextDecoder().decode(bytes));
          const send = (action, value = '') => window.webkit.messageHandlers.cap.postMessage({action,value});
          window.CapAndroid = {
            loadData: () => days,
            saveData: value => { if (value.length > 2000000) return false; send('days', value); days = value; return true; },
            loadProfile: () => profile,
            saveProfile: value => { if (value.length > 2000000) return false; send('profile', value); profile = value; return true; },
            exportCsv: value => send('export', value),
            importCsv: () => send('import')
          };
        })();
        """
        content.addUserScript(WKUserScript(source: bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        content.add(WeakCapHandler(self), name: "cap")

        let web = WKWebView(frame: .zero, configuration: configuration)
        web.uiDelegate = self
        web.navigationDelegate = self
        web.isOpaque = false
        web.backgroundColor = UIColor(red: 11/255, green: 12/255, blue: 22/255, alpha: 1)
        view.backgroundColor = web.backgroundColor
        view.addSubview(web)
        web.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            web.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor)
        ])
        webView = web
        web.loadHTMLString(capHTML, baseURL: nil)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.navigationType == .other && action.request.url?.absoluteString == "about:blank"
                        ? .allow : .cancel)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              let body = message.body as? [String: String],
              let action = body["action"], let value = body["value"],
              value.utf8.count <= 6_000_000 else { return }
        switch action {
        case "days", "profile":
            guard (try? JSONSerialization.jsonObject(with: Data(value.utf8))) is [String: Any] else { return }
            UserDefaults.standard.set(value, forKey: action == "days" ? daysKey : profileKey)
        case "export":
            exportCSV(value)
        case "import":
            guard presentedViewController == nil else { return }
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.commaSeparatedText, .plainText], asCopy: true)
            picker.delegate = self
            present(picker, animated: true)
        default:
            break
        }
    }

    private func exportCSV(_ value: String) {
        guard presentedViewController == nil else { return }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cap-suivi.csv")
        do {
            try value.write(to: file, atomically: true, encoding: .utf8)
            let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
            picker.delegate = self
            exportURL = file
            present(picker, animated: true)
        } catch {
            showAlert("Impossible de préparer le CSV.")
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if exportURL != nil {
            cleanExport()
            return
        }
        guard let file = urls.first else { return }
        let access = file.startAccessingSecurityScopedResource()
        defer { if access { file.stopAccessingSecurityScopedResource() } }
        do {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 2_000_000 else { showAlert("Ce CSV est trop volumineux."); return }
            let data = try Data(contentsOf: file)
            guard let csv = String(data: data, encoding: .utf8) else {
                showAlert("Impossible de lire ce CSV.")
                return
            }
            let encoded = try JSONEncoder().encode(csv)
            guard let literal = String(data: encoded, encoding: .utf8) else { return }
            webView?.evaluateJavaScript("window.capImportCsv(\(literal));")
        } catch {
            showAlert("Impossible de lire ce CSV.")
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        cleanExport()
    }

    private func cleanExport() {
        if let exportURL { try? FileManager.default.removeItem(at: exportURL) }
        exportURL = nil
    }

    private func showAlert(_ message: String, completion: @escaping () -> Void = {}) {
        let presenter = presentedViewController ?? self
        let alert = UIAlertController(title: "Cap", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completion() })
        presenter.present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        showAlert(message, completion: completionHandler)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let presenter = presentedViewController ?? self
        let alert = UIAlertController(title: "Cap", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Annuler", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "Confirmer", style: .default) { _ in completionHandler(true) })
        presenter.present(alert, animated: true)
    }
}

private final class WeakCapHandler: NSObject, WKScriptMessageHandler {
    weak var target: CapViewController?

    init(_ target: CapViewController) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

private let capHTML = #"""
<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'">
<meta name="theme-color" content="#0b0c16">
<meta name="description" content="Cap : ton suivi quotidien simple du poids, des calories, des pas et du sport.">
<title>Cap — Mon suivi quotidien</title>
<style>
:root {
  font-family: system-ui, -apple-system, "Segoe UI", sans-serif;
  color: #162d2a;
  background: #f1f5f3;
  font-synthesis: none;
  --ink: #162d2a;
  --muted: #526862;
  --accent: #006452;
  --line: #d9e5e0;
}
* { box-sizing: border-box; }
body, p, h1, h2 { margin: 0; }
button, input { font: inherit; }
button { cursor: pointer; }
button:focus-visible, input:focus-visible { outline: 3px solid #187d69; outline-offset: 3px; }
.wrap { max-width: 880px; margin: auto; padding: 16px 18px 44px; }
header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 16px; }
.brand { display: flex; gap: 10px; align-items: center; }
.logo { display: grid; place-items: center; width: 38px; height: 38px; background: #103a34; color: #fff; border-radius: 12px; font-size: 15px; font-weight: 800; }
.brand-name { font-size: 16px; font-weight: 750; }
.caption, .hint, .little, .note { color: var(--muted); font-size: 13px; line-height: 1.5; }
.subtle { display: flex; gap: 7px; align-items: center; color: #315c52; font-size: 12px; font-weight: 650; }
.dot { width: 7px; height: 7px; border-radius: 50%; background: #287b63; }
.hero { position: relative; isolation: isolate; overflow: hidden; padding: 27px 22px 30px; color: #fff; border-radius: 24px; background: linear-gradient(125deg, #102e2a, #135648); margin-bottom: 16px; }
.hero::before, .hero::after { content: ""; position: absolute; z-index: -1; width: 235px; height: 235px; border: 1px solid #b4f4d445; border-radius: 50%; right: -88px; top: -100px; }
.hero::after { transform: scale(1.24); }
.eyebrow { color: #b6ebd5; font-size: 11px; font-weight: 800; letter-spacing: .16em; text-transform: uppercase; }
h1 { margin: 7px 0 8px; font-size: clamp(29px, 7vw, 42px); line-height: 1.1; letter-spacing: -.045em; }
.intro { color: #d7eee6; font-size: 14px; line-height: 1.5; }
.panel { padding: 19px; margin-bottom: 16px; background: #fff; border: 1px solid var(--line); border-radius: 22px; box-shadow: 0 4px 14px #15362d08; }
h2 { font-size: 20px; letter-spacing: -.035em; }
.datebox, .sectionhead { display: flex; justify-content: space-between; align-items: center; gap: 12px; margin-bottom: 14px; }
.datebox p { color: var(--muted); font-size: 13px; margin-top: 4px; }
.dateactions { display: flex; align-items: center; gap: 5px; }
.navbtn, .dateactions input { height: 44px; border: 1px solid var(--line); border-radius: 12px; background: #f5f8f7; color: var(--ink); }
.navbtn { flex: 0 0 44px; font-size: 23px; }
.dateactions input { padding: 0 8px; min-width: 0; width: 142px; font-size: 14px; }
.fieldset { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 10px; margin: 16px 0 13px; }
.field label { display: block; margin-bottom: 6px; font-size: 13px; font-weight: 700; }
.field input { width: 100%; min-width: 0; height: 50px; padding: 0 10px; border: 1px solid var(--line); border-radius: 12px; background: #f5f8f7; color: var(--ink); font-size: 17px; font-weight: 700; }
.field input::placeholder { color: #657971; font-weight: 500; }
.hint { margin-top: 5px; font-size: 11px; }
.activity label { display: flex; justify-content: space-between; align-items: center; gap: 12px; min-height: 50px; padding: 9px 12px; border-radius: 12px; border: 1px solid var(--line); background: #f5f8f7; cursor: pointer; font-size: 14px; font-weight: 700; }
.activity label:has(input:checked) { background: #e4f5ed; border-color: #71b7a1; }
.activity input { appearance: none; position: relative; width: 42px; height: 24px; margin: 0; border-radius: 20px; background: #647972; cursor: pointer; }
.activity input::before { content: ""; position: absolute; top: 3px; left: 3px; width: 18px; height: 18px; border-radius: 50%; background: #fff; }
.activity input:checked { background: var(--accent); }
.activity input:checked::before { transform: translateX(18px); }
.actions, .backup { display: flex; align-items: center; gap: 9px; flex-wrap: wrap; margin-top: 13px; }
.btn-primary, .btn-secondary, .btn-ghost { min-height: 46px; padding: 10px 14px; border-radius: 12px; font-size: 14px; font-weight: 750; }
.btn-primary { border: 1px solid var(--accent); background: var(--accent); color: #fff; }
.btn-primary:active { background: #004a3e; }
.btn-secondary { border: 1px solid var(--line); background: #f5f8f7; color: var(--accent); }
.btn-ghost { border: 0; background: transparent; color: #983c32; }
.status { width: 100%; font-size: 13px; color: var(--accent); font-weight: 700; }
.status:empty { display: none; }
.overview { margin: 24px 0 16px; }
.metrics { display: grid; grid-template-columns: repeat(6, minmax(0, 1fr)); gap: 8px; margin: 12px 0 8px; }
.metric { grid-column: span 2; min-width: 0; padding: 12px 10px; background: #fff; border: 1px solid var(--line); border-radius: 16px; }
.metric:nth-last-child(-n+2) { grid-column: span 3; background: #e9f5ee; }
.klabel { color: var(--muted); font-size: 12px; font-weight: 700; }
.metric strong { display: block; margin: 5px 0 3px; font-size: clamp(17px, 4.5vw, 25px); letter-spacing: -.045em; font-variant-numeric: tabular-nums; overflow-wrap: anywhere; }
.metric small { display: block; font-size: 11px; color: var(--muted); line-height: 1.4; }
.sectionhead .caption { text-align: right; }
.chart-panel .dateactions { margin-bottom: 8px; }
.chartwrap { width: 100%; }
.chartwrap svg { display: block; width: 100%; height: auto; min-height: 120px; }
.empty { padding: 25px 12px; margin-top: 12px; text-align: center; font-size: 13px; color: var(--muted); background: #f5f8f7; border-radius: 13px; }
.grid2 { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 14px; }
.dailybars { display: grid; grid-template-columns: repeat(7, minmax(0, 1fr)); gap: 4px; margin: 14px 0 8px; }
.daybar { min-width: 0; text-align: center; }
.barspace { height: 94px; display: flex; align-items: flex-end; justify-content: center; border-radius: 8px; background: #eef4f1; }
.bar { width: 65%; max-width: 30px; background: #187b68; border-radius: 5px 5px 0 0; }
#calChart .bar { background: #526da1; }
.daybar small, .daybar b { display: block; font-size: 10px; font-variant-numeric: tabular-nums; color: var(--muted); }
.daybar small { margin-top: 5px; }
.daybar b { color: var(--ink); }
.history { display: grid; gap: 6px; }
.historyitem { width: 100%; display: flex; justify-content: space-between; align-items: center; gap: 8px; text-align: left; padding: 11px 12px; border: 1px solid var(--line); border-radius: 12px; background: #f7faf8; color: var(--ink); }
.hdate { font-size: 14px; font-weight: 750; }
.hsummary { margin-top: 4px; font-size: 12px; line-height: 1.5; color: var(--muted); }
.chev { font-size: 22px; color: var(--accent); }
.note { margin-top: 10px; }
.foot { text-align: center; color: var(--muted); font-size: 12px; margin-top: 18px; }
.sr-only { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0,0,0,0); white-space: nowrap; }
@media (max-width: 580px) {
  .wrap { padding-inline: 13px; }
  .panel { padding: 15px; }
  .datebox { display: block; }
  .datebox .dateactions { margin-top: 10px; }
  .dateactions input { flex: 1; width: auto; }
  .grid2 { grid-template-columns: 1fr; gap: 0; }
  .btn-primary { width: 100%; }
}
@media (max-width: 350px) {
  .fieldset { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .metric { padding-inline: 7px; }
}
/* Palette nocturne et accents électriques */
:root {
  color-scheme: dark;
  background: #0b0c16;
  color: #f5f5ff;
  --ink: #f5f5ff;
  --muted: #aeb0ca;
  --accent: #c9ff70;
  --line: #32334f;
}
body { background: radial-gradient(ellipse 440px 400px at 88% 0%, #29214a 0, transparent 100%); }
.brand-name { font-size: 19px; letter-spacing: -.055em; }
.logo { color: #101419; background: #c9ff70; border-radius: 13px 5px 13px 5px; transform: skew(-5deg); }
.subtle { color: #d1d0e8; }
.dot { background: #c9ff70; box-shadow: 0 0 10px #c9ff7070; }
.hero {
  padding: 28px 21px 31px;
  background: radial-gradient(ellipse at 100% 10%, #6553af 0%, transparent 66%), linear-gradient(135deg,#28213f,#242542);
  border: 1px solid #645681;
  border-radius: 26px 10px 26px 10px;
}
.hero::before, .hero::after { border-color: #d3c4ff65; top: -88px; right: -83px; }
.eyebrow { color: #d7ff9e; }
h1 { max-width: 330px; font-size: clamp(33px, 9vw, 49px); line-height: 1; }
.intro { color: #e1daf8; }
.panel { background: #17182a; box-shadow: 0 8px 22px #0003; }
.navbtn, .dateactions input, .field input, .activity label, .btn-secondary, .empty, .historyitem {
  color: var(--ink);
  background: #202137;
}
.field input::placeholder { color: #a4a5c1; }
.activity label:has(input:checked) { background: #2a372d; border-color: #8db654; }
.activity input { background: #6b6c8d; }
.activity input:checked::before { background: #191f19; }
.btn-primary { color: #141a11; box-shadow: 0 4px 18px #c9ff7022; }
.btn-primary:active { background: #abd85d; }
.btn-ghost { color: #ffa99f; }
button:focus-visible, input:focus-visible { outline-color: #c9ff70; }
.metric { background: #1b1c30; }
.metric:nth-last-child(-n+2) { background: #282340; border-color: #51446f; }
.metric:nth-last-child(-n+2) strong { color: #ded0ff; }
.barspace { background: #23243b; }
.bar { background: linear-gradient(#ceff88,#74a941); }
.bar { display: flex; flex-direction: column; overflow: hidden; background: linear-gradient(#a9c2ff,#627aad); }
#calChart .bar { background: linear-gradient(#d7bdff,#8e6ad1); }
.bar-gap { flex: none; width: 100%; }
.bar-gap.green { background: #baff53; }
.bar-gap.red { background: #ff616f; }
.page-nav { display: flex; gap: 8px; margin-bottom: 16px; }
.page-nav button { flex: 1; }
.page-nav button[aria-pressed="true"] { background: var(--accent); color: #141a11; border-color: var(--accent); }
.profile-fields { grid-template-columns: repeat(2,minmax(0,1fr)); }
.profile-summary, #profilePage .status { margin-top: 10px; }
.goal-history { margin: 10px 0 0; padding-left: 20px; color: var(--muted); line-height: 1.6; font-size: 13px; }
.page-nav button { min-width: 0; padding-inline: 7px; }
.chart-help { margin: 0 0 16px; }
.chart-help summary { cursor: pointer; font-weight: 750; padding-block: 4px; }
.chart-help ul { margin: 8px 0 0; padding-left: 19px; }
.sport-week { margin-top: 12px; }
.sport-week .barspace { height: 84px; }
.sport-week .bar { background: linear-gradient(#ceff88,#74a941); }
.data-toolbar { margin-top: 10px; }
.brand-goal { color: #c9ff70; font-size: 19px; font-weight: 850; letter-spacing: -.055em; }
.weight-point { cursor: pointer; }
.weight-point:focus-visible, .weight-point[aria-pressed="true"] { stroke: #fff; stroke-width: 2; outline: none; }
.weight-readout { margin-top: 6px; color: #d7ff9e; font-weight: 750; }
.sport-week .bar { background: linear-gradient(#a9c2ff,#627aad); }
.sport-week .bar.reached { background: #7ab945; }
.sport-week .bar.reached .bar-gap.green { background: #c9ff70; }
.google-actions { display: flex; gap: 8px; align-items: center; margin-top: 12px; }
.google-actions button:disabled { opacity: .6; }
</style>
</head>
<body>
<div class="wrap">
  <header><div class="brand"><span class="logo" aria-hidden="true">C</span><span class="brand-name">Cap</span><span id="brandGoal" class="brand-goal" hidden></span></div><div class="subtle"><span class="dot"></span>Suivi local</div></header>
  <nav class="page-nav" aria-label="Navigation Cap">
    <button type="button" class="btn-secondary" id="navTracking" aria-pressed="true" aria-controls="trackingPage">Suivi</button>
    <button type="button" class="btn-secondary" id="navProfile" aria-pressed="false" aria-controls="profilePage">Mon profil</button>
    <button type="button" class="btn-secondary" id="navData" aria-pressed="false" aria-controls="dataPage">Données</button>
  </nav>
  <div id="trackingPage">
  <div class="hero"><p class="eyebrow">Suivi quotidien</p><h1>À ton rythme.</h1><p class="intro">Poids, activité et alimentation</p></div>
  <main>
    <section class="panel" aria-label="Saisie quotidienne">
      <div class="datebox"><div><h2>Ma journée</h2><p id="dateSummary">Choisis une date et renseigne tes chiffres.</p></div><div class="dateactions"><button id="back" type="button" class="navbtn" aria-label="Jour précédent">‹</button><input id="day" type="date" aria-label="Date de suivi"><button id="forward" type="button" class="navbtn" aria-label="Jour suivant">›</button></div></div>
      <div class="fieldset">
        <div class="field"><label for="cal">Calories (kcal)</label><input id="cal" type="number" min="0" max="20000" step="1" inputmode="numeric" placeholder="2000"><p class="hint">Total du jour</p></div>
        <div class="field"><label for="steps">Pas</label><input id="steps" type="number" min="0" max="100000" step="1" inputmode="numeric" placeholder="10000"><p class="hint" id="dayStepsGoal"></p></div>
        <div class="field"><label for="weight">Poids (kg)</label><input id="weight" type="number" min="20" max="400" step="0.1" inputmode="decimal" placeholder="113,0"><p class="hint">Pesée du matin</p></div>
      </div>
      <div class="activity"><label><span>Sport</span><input id="sport" type="checkbox"></label></div>
      <div class="actions"><button id="save" type="button" class="btn-primary">Enregistrer ma journée</button><button id="delete" type="button" class="btn-ghost" hidden>Supprimer ce jour</button><div id="status" class="status" role="status" aria-live="polite"></div></div>
    </section>
    <section class="overview" aria-labelledby="overview-title"><h2 id="overview-title">En bref</h2><div class="metrics">
      <div class="metric"><div class="klabel">Dernier poids</div><strong id="mWeight">—</strong><small id="mDelta">Aucune pesée</small></div>
      <div class="metric"><div class="klabel">Pas moyens / jour</div><strong id="mSteps">—</strong><small>Sur 7 jours suivis</small></div>
      <div class="metric"><div class="klabel">Sport cette semaine</div><strong id="mSport">0</strong><small>Jours avec du sport</small></div>
      <div class="metric"><div class="klabel">Calories moyennes · 7 jours</div><strong id="mCal7">—</strong><small id="mCalCount7"></small></div>
      <div class="metric"><div class="klabel">Calories moyennes · 30 jours</div><strong id="mCal30">—</strong><small id="mCalCount30"></small></div>
    </div>
    </section>
    <details class="panel chart-help">
      <summary>Comment lire mes graphiques ?</summary>
      <ul class="caption">
        <li>Utilise les flèches pour reculer ou avancer. Choisis une date pour retrouver une période précise.</li>
        <li>Appuie sur un point du poids pour voir la mesure de ce jour.</li>
        <li>Le graphique Sport compte les jours cochés. Un jour avec deux séances compte une fois.</li>
      </ul>
    </details>
    <section class="panel chart-panel"><div class="sectionhead"><h2>Évolution du poids</h2><span class="caption">30 jours</span></div>
      <div class="dateactions" role="group" aria-label="Période du poids">
        <button id="weightChartBack" type="button" class="navbtn" aria-label="Période précédente du poids">‹</button>
        <input id="weightChartEnd" type="date" aria-label="Date de fin du poids">
        <button id="weightChartForward" type="button" class="navbtn" aria-label="Période suivante du poids">›</button>
      </div><p id="weightChartRange" class="caption" aria-live="polite"></p><div id="weightChart" class="chartwrap"><div class="empty">Ajoute ta première pesée pour voir la courbe.</div></div></section>
    <div class="grid2">
      <section class="panel chart-panel"><div class="sectionhead"><h2>Mes pas</h2><span class="caption">7 jours</span></div>
      <div class="dateactions" role="group" aria-label="Période des pas">
        <button id="stepsChartBack" type="button" class="navbtn" aria-label="Période précédente des pas">‹</button>
        <input id="stepsChartEnd" type="date" aria-label="Date de fin des pas">
        <button id="stepsChartForward" type="button" class="navbtn" aria-label="Période suivante des pas">›</button>
      </div><p id="stepsChartRange" class="caption" aria-live="polite"></p><div id="stepsChart"></div></section>
      <section class="panel chart-panel"><div class="sectionhead"><h2>Calories</h2><span class="caption">7 jours</span></div>
      <div class="dateactions" role="group" aria-label="Période des calories">
        <button id="calChartBack" type="button" class="navbtn" aria-label="Période précédente des calories">‹</button>
        <input id="calChartEnd" type="date" aria-label="Date de fin des calories">
        <button id="calChartForward" type="button" class="navbtn" aria-label="Période suivante des calories">›</button>
      </div><p id="calChartRange" class="caption" aria-live="polite"></p><div id="calChart"></div></section>
    </div>
    <section class="panel chart-panel">
      <div class="sectionhead"><h2>Sport par semaine</h2><span class="caption">4 semaines</span></div>
      <div class="dateactions" role="group" aria-label="Période du sport">
        <button id="sportChartBack" type="button" class="navbtn" aria-label="Période précédente du sport">‹</button>
        <input id="sportChartEnd" type="date" aria-label="Date de fin du sport">
        <button id="sportChartForward" type="button" class="navbtn" aria-label="Période suivante du sport">›</button>
      </div>
      <p id="sportChartRange" class="caption" aria-live="polite"></p>
      <div id="sportChart"></div>
      
    </section>
  </main>
  </div>
  <main id="profilePage" hidden>
    <div class="hero"><p class="eyebrow">Ton espace</p><h1>Mon profil</h1><p class="intro">Tes infos et tes objectifs, à ton rythme.</p></div>
    <section class="panel" aria-labelledby="googleTitle" id="googlePanel" hidden>
      <h2 id="googleTitle">Compte Google</h2>
      <p class="caption profile-summary" id="googleAccount"></p>
      <div class="google-actions">
        <button type="button" class="btn-secondary" id="googleSignIn">Continuer avec Google</button>
        <button type="button" class="btn-secondary" id="googleSignOut" hidden>Se déconnecter</button>
      </div>
      <p class="status" role="status" id="googleStatus"></p>
    </section>
    <section class="panel" aria-labelledby="profileTitle">
      <h2 id="profileTitle">Mes infos</h2>
      <form id="profileForm">
        <div class="fieldset profile-fields">
          <div class="field"><label for="profileName">Prénom (facultatif)</label><input id="profileName" type="text" autocomplete="given-name" maxlength="60"></div>
          <div class="field"><label for="goalWeight">Poids cible (kg)</label><input id="goalWeight" type="number" min="20" max="400" step="any" inputmode="decimal" placeholder="Facultatif"></div>
        </div>
        <button type="submit" class="btn-primary">Enregistrer mes infos</button>
        <p id="profileStatus" class="status" role="status"></p>
      </form>
      <p id="profileWeight" class="caption profile-summary"></p>
    </section>
    <section class="panel" aria-labelledby="goalsTitle">
      <h2 id="goalsTitle">Mes objectifs quotidiens</h2>
      <p id="currentGoals" class="caption profile-summary"></p>
      <form id="goalsForm">
        <div class="fieldset profile-fields">
          <div class="field"><label for="goalCalories">Calories (kcal)</label><input id="goalCalories" type="number" required min="1" max="20000" inputmode="numeric"></div>
          <div class="field"><label for="goalSteps">Pas</label><input id="goalSteps" type="number" required min="1" max="100000" inputmode="numeric"></div>
          <div class="field"><label for="goalSport">Sport par semaine</label><input id="goalSport" type="number" min="1" max="7" step="1" inputmode="numeric" placeholder="Facultatif" aria-describedby="goalSportHint"><p class="hint" id="goalSportHint">De 1 à 7 jours</p></div>
          <div class="field"><label for="goalDate">À partir du</label><input id="goalDate" type="date" required></div>
        </div>
        <button type="submit" class="btn-primary">Enregistrer ces objectifs</button>
        <p id="goalStatus" class="status" role="status"></p>
      </form>
    </section>
    <section class="panel" aria-labelledby="goalHistoryTitle">
      <h2 id="goalHistoryTitle">Historique des objectifs</h2>
      <ul class="goal-history" id="goalHistory"></ul>
    </section>
  </main>
  <main id="dataPage" hidden>
    <div class="hero"><p class="eyebrow">Ton journal</p><h1>Mes données</h1><p class="intro">Retrouve tes journées et sauvegarde ton suivi.</p></div>
    <section class="panel"><div class="sectionhead"><h2>Mes sauvegardes</h2></div><p class="caption">Tes données sont sauvegardées sur cet appareil après chaque enregistrement.</p><div class="backup"><button class="btn-secondary" id="export" type="button">↓ Exporter mon CSV</button><button class="btn-secondary" id="import" type="button">↑ Importer un CSV</button><input id="csvfile" class="sr-only" type="file" accept=".csv,text/csv"></div><p class="note">Le CSV contient une seule ligne par jour. Le CSV reprend les journées enregistrées sur cet appareil. Utilise « Exporter » pour obtenir une copie dans tes fichiers. Sauvegarde ton CSV avant de désinstaller l’application.</p></section>
    <section class="panel"><div class="sectionhead"><h2>Historique</h2><span class="caption">Choisis une journée pour la modifier</span></div><div id="history" class="history"></div><button type="button" class="btn-secondary data-toolbar" id="moreHistory" hidden>Afficher plus de journées</button></section>
  </main>
  <div class="foot">Cap · Suivi personnel</div>
</div>
<script>
(()=>{'use strict';
const KEY='cap_personal_v1',BASE_HEADERS=['date','calories_kcal','poids_kg','pas'],HEADERS=[...BASE_HEADERS,'sport'];
const DEFAULT_GOALS={calories:2000,steps:10000};
const PROFILE_KEY=KEY+'_profile';
let profile={name:'',weight:null,goals:{}};
try {
 const raw=window.CapAndroid?.loadProfile?.() ?? localStorage.getItem(PROFILE_KEY);
 const saved=JSON.parse(raw||'null');
 if(saved)profile={...profile,...saved,goals:saved.goals??{}};
} catch(e){console.warn('Lecture du profil impossible',e)}
function goalsFor(day){
 const date=Object.keys(profile.goals).filter(date=>date<=day).sort().pop();
 return date?profile.goals[date]:DEFAULT_GOALS;
}
function saveProfile(next,status){
 try {
   if(window.CapAndroid?.saveProfile){
     if(!window.CapAndroid.saveProfile(JSON.stringify(next)))throw Error('Profil');
   }else localStorage.setItem(PROFILE_KEY,JSON.stringify(next));
   profile=next;
   $(status).textContent='✓ Enregistré';
   return true;
 }catch(e){
   $(status).textContent='Enregistrement impossible. Réessaie.';
   return false;
 }
}
const hasSport=d=>d.sport ?? Boolean(d.muscu || d.pool);
const $=id=>document.getElementById(id);
const num=n=>Number(n).toLocaleString('fr-FR',{maximumFractionDigits:1});
const today=()=>{const d=new Date();return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`};
const plus=(day,n)=>{const d=new Date(day+'T12:00:00');d.setDate(d.getDate()+n);return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`};
const validDate=s=>/^\d{4}-\d{2}-\d{2}$/.test(s)&&!Number.isNaN(new Date(s+'T12:00:00').getTime())&&plus(s,0)===s;
const shortDay=s=>new Intl.DateTimeFormat('fr-FR',{weekday:'short'}).format(new Date(s+'T12:00:00')).replace('.','');
const longDay=s=>new Intl.DateTimeFormat('fr-FR',{day:'numeric',month:'long',year:'numeric'}).format(new Date(s+'T12:00:00'));
let entries={};let selected=today();let toastTimer;
const charts = [
 {id:'weightChart', days:30, end:today(), draw:(start,end)=>plotWeight(
   Object.entries(entries).filter(([day,d])=>validDate(day)&&day>=start&&day<=end&&d?.weight!=null&&Number.isFinite(Number(d.weight))).sort(([a],[b])=>a.localeCompare(b)),
   start,end)},
 {id:'stepsChart', days:7, end:today(), draw:start=>plotBars('stepsChart',weekFrom(start),'steps')},
 {id:'calChart', days:7, end:today(), draw:start=>plotBars('calChart',weekFrom(start),'calories')},
 {id:'sportChart', days:28, end:today(), draw:plotSport}
];
function weekFrom(start){
 return Array.from({length:7},(_,i)=>{const key=plus(start,i);return {...entries[key],key}});
}
function renderChart(chart){
 const start=plus(chart.end,1-chart.days);
 $(chart.id+'End').value=chart.end;
 $(chart.id+'Range').textContent='Du '+longDay(start)+' au '+longDay(chart.end);
 chart.draw(start,chart.end);
}
for(const chart of charts){
 const change=end=>{
   if(validDate(end))chart.end=end;
   renderChart(chart);
 };
 $(chart.id+'Back').onclick=()=>change(plus(chart.end,-chart.days));
 $(chart.id+'Forward').onclick=()=>change(plus(chart.end,chart.days));
 $(chart.id+'End').onchange=e=>change(e.target.value);
}
function renderCalorieAverages(){
 const end=today();
 for(const days of [7,30]){
   const start=plus(end,1-days);
   const calories=Object.entries(entries)
     .filter(([day,d])=>validDate(day)&&day>=start&&day<=end&&Number.isFinite(d?.calories))
     .map(([,d])=>d.calories);
   const count=calories.length;
   $('mCal'+days).textContent=count?num(calories.reduce((sum,n)=>sum+n,0)/count)+' kcal':'—';
   $('mCalCount'+days).textContent=count+'/'+days+' jours renseignés';
 }
}
try {
 const androidData=window.CapAndroid&&typeof window.CapAndroid.loadData==='function'?window.CapAndroid.loadData():'';
 const obj=JSON.parse(androidData||localStorage.getItem(KEY)||'{}');
 if(obj&&typeof obj==='object'&&!Array.isArray(obj))entries=obj;
} catch(e){console.warn('Lecture des données impossible',e)}
// Compatibilité avec les premières versions de Cap qui classaient les calories par repas.
for(const v of Object.values(entries)){if(v&&Array.isArray(v.meals)&&v.calories==null){v.calories=v.meals.reduce((sum,m)=>sum+(Number(m?.kcal)||0),0)}}
function persist(){
 const json=JSON.stringify(entries);
 if(window.CapAndroid&&typeof window.CapAndroid.saveData==='function'){
   try{
     if(!window.CapAndroid.saveData(json))throw Error('Enregistrement Android impossible');
     try{localStorage.setItem(KEY,json)}catch(e){} // copie facultative
     return true;
   }catch(e){alert('Impossible d’enregistrer sur le téléphone. Réessaie puis exporte ton CSV.');return false}
 }
 try{localStorage.setItem(KEY,json);return true}catch(e){alert('Sauvegarde locale bloquée. Exporte ton CSV.');return false}
}
function info(s){$('status').textContent=s;clearTimeout(toastTimer);toastTimer=setTimeout(()=>$('status').textContent='',3500)}
function get(){return entries[selected]||{}}
function open(day){if(!validDate(day))return;selected=day;render();window.scrollTo({top:0,behavior:'smooth'})}
function render(){
 const d=get();$('dayStepsGoal').textContent='Objectif · '+num(goalsFor(selected).steps);$('day').value=selected;$('dateSummary').textContent=selected===today()?"Aujourd'hui • "+longDay(selected):longDay(selected);
 $('cal').value=d.calories??'';$('steps').value=d.steps??'';$('weight').value=d.weight??'';$('sport').checked=hasSport(d);$('delete').hidden=!Object.prototype.hasOwnProperty.call(entries,selected);
 const through=Object.entries(entries).filter(([k,v])=>validDate(k)&&k<=selected&&v&&typeof v==='object');
 const weigh=through.filter(([,v])=>Number.isFinite(Number(v.weight))&&v.weight!=null).sort(([a],[b])=>a.localeCompare(b));
 if(weigh.length){const first=Number(weigh[0][1].weight),last=Number(weigh[weigh.length-1][1].weight),diff=Math.round((last-first)*10)/10;$('mWeight').textContent=num(last)+' kg';$('mDelta').textContent=weigh.length>1?(diff>0?'+':'')+num(diff)+' kg depuis le début':'Première mesure';}else{$('mWeight').textContent='—';$('mDelta').textContent='Aucune pesée'}
 const week=weekFrom(plus(selected,-6));
 const tracked=week.filter(x=>x.steps!==undefined&&x.steps!==null&&Number.isFinite(Number(x.steps)));
 $('mSteps').textContent=tracked.length?num(Math.round(tracked.reduce((a,x)=>a+Number(x.steps),0)/tracked.length)):'—';
 const monday=(()=>{const x=new Date(selected+'T12:00:00');return plus(selected,-(x.getDay()+6)%7)})();
 const sports=through.filter(([k,v])=>k>=monday&&hasSport(v)).length;
 $('mSport').textContent=sports;
 renderCalorieAverages();charts.forEach(renderChart);history();
}
function plotWeight(points,start,end){const target=$('weightChart');target.replaceChildren();if(!points.length){const e=document.createElement('div');e.className='empty';e.textContent='Aucune pesée sur cette période.';target.append(e);return}
 const w=360,h=165,l=42,r=14,t=18,b=27;const values=points.map(p=>Number(p[1].weight)),min=Math.min(...values)-.6,max=Math.max(...values)+.6;const plotW=w-l-r,plotH=h-t-b;
 const x=d=>l+(Date.parse(d)-Date.parse(start))/(Date.parse(end)-Date.parse(start))*plotW;
 const y=v=>t+(max-v)/(max-min)*plotH;
 const mk=(tag,attrs)=>{const el=document.createElementNS('http://www.w3.org/2000/svg',tag);Object.entries(attrs||{}).forEach(([k,v])=>el.setAttribute(k,String(v)));return el};
 const svg=mk('svg',{viewBox:`0 0 ${w} ${h}`,role:'group','aria-label':'Courbe du poids sur la période'});
 for(let i=0;i<4;i++){const yy=t+i*plotH/3;svg.append(mk('line',{x1:l,x2:w-r,y1:yy,y2:yy,stroke:'#353751','stroke-width':1}));const txt=mk('text',{x:l-8,y:yy+4,'text-anchor':'end',fill:'#b8b9d0','font-size':11});txt.textContent=num(Math.round((max-(max-min)*i/3)*10)/10);svg.append(txt)}
 if(points.length>1){svg.append(mk('polyline',{points:points.map(([d,v])=>`${x(d).toFixed(1)},${y(Number(v.weight)).toFixed(1)}`).join(' '),fill:'none',stroke:'#c9ff70','stroke-width':3,'stroke-linejoin':'round','stroke-linecap':'round'}))}
 const readout=document.createElement('p');
 readout.className='caption weight-readout';
 readout.setAttribute('role','status');
 let activePoint;
 for(const [day,entry] of points){
   const detail=longDay(day)+' · '+num(entry.weight)+' kg';
   const point=mk('circle',{cx:x(day),cy:y(Number(entry.weight)),r:4.5,fill:'#c9ff70',class:'weight-point',
     tabindex:0,role:'button','aria-label':detail,'aria-pressed':'false'});
   function showWeight(){
     if(activePoint)activePoint.setAttribute('aria-pressed','false');
     point.setAttribute('aria-pressed','true');
     activePoint=point;
     readout.textContent=detail;
   }
   point.addEventListener('click',showWeight);
   point.addEventListener('keydown',event=>{
     if(event.key==='Enter'||event.key===' '){event.preventDefault();showWeight()}
   });
   svg.append(point);
 }
 const st=mk('text',{x:l,y:h-8,fill:'#b8b9d0','font-size':11});st.textContent=longDay(start);const en=mk('text',{x:w-r,y:h-8,fill:'#b8b9d0','font-size':11,'text-anchor':'end'});en.textContent=longDay(end);svg.append(st,en);target.append(svg,readout)
}
function appendBarGap(bar,green,fraction){
 const gap=document.createElement('div');
 gap.className='bar-gap '+(green?'green':'red');
 gap.style.height=(100*fraction)+'%';
 bar.append(gap);
}
function plotBars(id,week,key){
 const host=$(id);
 host.replaceChildren();
 const container=document.createElement('div');
 container.className='dailybars';
 const largest=Math.max(...week.map(d=>Math.max(goalsFor(d.key)[key],Number(d[key])||0)));
 const isSteps=key==='steps';
 for(const d of week){
   const outer=document.createElement('div');
   outer.className='daybar';
   const space=document.createElement('div');
   space.className='barspace';
   const bar=document.createElement('div');
   bar.className='bar';
   const has=d[key]!=null&&d[key]!=='';
   const amount=Number(d[key]);
   const goal=goalsFor(d.key)[key];
   if(has){
     const total=Math.max(amount,goal);
     bar.style.height=(90*total/largest)+'px';
     if(amount!==goal){
       const green=isSteps?amount>goal:amount<goal;
       appendBarGap(bar,green,Math.abs(amount-goal)/total);
     }
   }
   const unit=isSteps?' pas':' kcal';
   bar.title=longDay(d.key)+' : '+(has?num(amount)+unit:'non renseigné');
   if(has&&amount!==goal){
     bar.title+=' ('+num(Math.abs(amount-goal))+unit+(amount>goal?' au-dessus':' en dessous')+' de l’objectif)';
   }
   space.append(bar);
   const label=document.createElement('small');
   label.textContent=shortDay(d.key);
   const value=document.createElement('b');
   value.textContent=has?(isSteps?num(Math.round(amount/100)/10)+'k':num(amount)):'—';
   outer.append(space,label,value);
   container.append(outer);
 }
 host.append(container);
}
function plotSport(start){
 const host=$('sportChart');
 const container=document.createElement('div');
 container.className='dailybars sport-week';
 container.style.gridTemplateColumns='repeat(4,minmax(0,1fr))';
 const dateLabel=new Intl.DateTimeFormat('fr-FR',{day:'numeric',month:'short'});
 for(let i=0;i<4;i++){
   const first=plus(start,i*7);
   const week=weekFrom(first);
   const count=week.filter(hasSport).length;
   const item=document.createElement('div');
   item.className='daybar';
   const track=document.createElement('div');
   track.className='barspace';
   const bar=document.createElement('div');
   bar.className='bar';
   const goal=goalsFor(week[6].key).sport;
   const total=Math.max(count,goal??0);
   bar.style.height=(total/7*100)+'%';
   if(goal!=null){
     if(count>=goal)bar.classList.add('reached');
     if(count!==goal)appendBarGap(bar,count>goal,Math.abs(count-goal)/total);
   }
   track.append(bar);
   const date=document.createElement('small');
   date.textContent='Dès le '+dateLabel.format(new Date(first+'T12:00:00'));
   const value=document.createElement('b');
   value.textContent=goal==null?count+(count===1?' jour':' jours'):count+' / '+goal+' j';
   item.title='Du '+longDay(first)+' au '+longDay(week[6].key)+(goal==null?'':' · Objectif : '+goal+' jours');
   item.append(track,date,value);
   container.append(item);
 }
 host.replaceChildren(container);
}
let historyLimit=10;
$('moreHistory').onclick=()=>{historyLimit+=10;history()};
function history(){const host=$('history');host.replaceChildren();const days=Object.keys(entries).filter(validDate).sort().reverse();$('moreHistory').hidden=days.length<=historyLimit;if(!days.length){const el=document.createElement('div');el.className='empty';el.textContent='Aucune journée enregistrée pour le moment.';host.append(el);return}for(const k of days.slice(0,historyLimit)){const d=entries[k];const button=document.createElement('button');button.type='button';button.className='historyitem';button.addEventListener('click',()=>{showPage('Tracking');open(k)});const div=document.createElement('div'),date=document.createElement('div'),details=document.createElement('div'),arrow=document.createElement('span');date.className='hdate';date.textContent=longDay(k);details.className='hsummary';details.textContent=[d.calories!=null?num(d.calories)+' kcal':null,d.steps!=null?num(d.steps)+' pas':null,d.weight!=null?num(d.weight)+' kg':null,hasSport(d)?'Sport':null].filter(Boolean).join(' · ')||'Journée enregistrée';div.append(date,details);arrow.className='chev';arrow.textContent='›';button.append(div,arrow);host.append(button)}}
$('back').onclick=()=>open(plus(selected,-1));$('forward').onclick=()=>open(plus(selected,1));$('day').onchange=e=>open(e.target.value);
$('save').onclick=()=>{const cs=$('cal').value.trim(),ss=$('steps').value.trim(),ws=$('weight').value.trim(),sport=$('sport').checked;
 if(cs===''&&ss===''&&ws===''&&!sport){info('Renseigne au moins une information.');return}
 if((cs!==''&&(!Number.isInteger(+cs)||+cs<0||+cs>20000))||(ss!==''&&(!Number.isInteger(+ss)||+ss<0||+ss>100000))||(ws!==''&&(!Number.isFinite(Number(ws))||Number(ws)<20||Number(ws)>400))){info('Vérifie les chiffres saisis.');return}
 const d={sport};if(cs!=='')d.calories=+cs;if(ss!=='')d.steps=+ss;if(ws!=='')d.weight=+ws;const previous=entries[selected];entries[selected]=d;
 if(!persist()){if(previous===undefined)delete entries[selected];else entries[selected]=previous;return}render();info('✓ Journée enregistrée')};
$('delete').onclick=()=>{if(!confirm('Supprimer les données du '+longDay(selected)+' ?'))return;const old=entries[selected];delete entries[selected];if(!persist()){entries[selected]=old;return}render();info('Journée supprimée')};
function csvText(){const rows=[HEADERS.join(';')];for(const day of Object.keys(entries).filter(validDate).sort()){const d=entries[day];rows.push([day,d.calories??'',d.weight!=null?String(d.weight).replace('.',','):'',d.steps??'',hasSport(d)?'1':'0'].join(';'))}return '\ufeff'+rows.join('\r\n')+'\r\n'}
$('export').onclick=()=>{if(window.CapAndroid&&typeof window.CapAndroid.exportCsv==='function'){window.CapAndroid.exportCsv(csvText());return}const blob=new Blob([csvText()],{type:'text/csv;charset=utf-8'});const uri=URL.createObjectURL(blob),a=document.createElement('a');a.href=uri;a.download='cap-suivi-'+today()+'.csv';document.body.append(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(uri),3000);info('✓ CSV téléchargé')};
$('import').onclick=()=>{if(window.CapAndroid&&typeof window.CapAndroid.importCsv==='function'){window.CapAndroid.importCsv();return}$('csvfile').click()};
async function importCsvContents(contents){try{const lines=contents.replace(/^\ufeff/,'').trim().split(/\r?\n/).filter(Boolean);if(!lines.length)throw Error('CSV vide');const sep=lines[0].includes(';')?';':',';const headers=lines.shift().split(sep).map(v=>v.trim().toLowerCase());const modern=headers.includes('sport');if(!BASE_HEADERS.every(h=>headers.includes(h))||(!modern&&!['musculation','piscine'].every(h=>headers.includes(h))))throw Error('CSV non reconnu');const incoming={};for(const line of lines){const cells=line.split(sep),row=Object.fromEntries(headers.map((h,i)=>[h,(cells[i]??'').trim()]));if(!validDate(row.date))throw Error('Date incorrecte');const isChecked=value=>['1','oui','true'].includes(value.toLowerCase());const d={sport:modern?isChecked(row.sport):isChecked(row.musculation)||isChecked(row.piscine)};for(const [col,target,max,minimum,integer] of [['calories_kcal','calories',20000,0,true],['poids_kg','weight',400,20,false],['pas','steps',100000,0,true]]){if(row[col]!==''){const n=Number(row[col].replace(',','.'));if(!Number.isFinite(n)||n<minimum||n>max||(integer&&!Number.isInteger(n)))throw Error('Chiffre incorrect');d[target]=n}}incoming[row.date]=d}const n=Object.keys(incoming).length;if(!confirm('Importer '+n+' journée(s) ? Les mêmes dates seront remplacées.'))return;const old=entries;entries={...entries,...incoming};if(!persist()){entries=old;return}render();info('✓ '+n+' journée(s) importée(s)')}catch(e){alert('Impossible d’importer ce fichier CSV. Utilise un export de Cap.')}}
window.capImportCsv=importCsvContents;
$('csvfile').onchange=async ev=>{const file=ev.target.files&&ev.target.files[0];if(!file)return;await importCsvContents(await file.text());ev.target.value=''};
function setGoalInputs(date){
 const goals=goalsFor(date);
 $('goalCalories').value=goals.calories;
 $('goalSteps').value=goals.steps;
 $('goalSport').value=goals.sport??'';
}
function renderBrandGoal(){
 const label=$('brandGoal');
 label.hidden=profile.weight==null;
 label.textContent=profile.weight==null?'':num(profile.weight);
 label.setAttribute('aria-label',profile.weight==null?'':'Poids cible : '+num(profile.weight)+' kg');
}
function refreshProfile(){
 const latest=Object.keys(entries).filter(day=>day<=today()&&Number.isFinite(entries[day]?.weight)).sort().pop();
 $('profileWeight').textContent=latest?'Dernière pesée · '+num(entries[latest].weight)+' kg':'Aucune pesée enregistrée.';
 const format=goals=>num(goals.calories)+' kcal · '+num(goals.steps)+' pas'+(goals.sport==null?'':' · Sport '+goals.sport+' j/sem.');
 $('currentGoals').textContent='En vigueur aujourd’hui · '+format(goalsFor(today()));
 const list=$('goalHistory');
 list.replaceChildren();
 const dates=Object.keys(profile.goals).sort().reverse();
 for(const date of dates){
   const item=document.createElement('li');
   item.textContent=longDay(date)+' · '+format(profile.goals[date]);
   list.append(item);
 }
 const initial=document.createElement('li');
 initial.textContent='Objectifs de départ · '+format(DEFAULT_GOALS);
 list.append(initial);
}
const pages={Tracking:'trackingPage',Profile:'profilePage',Data:'dataPage'};
function showPage(active){
 for(const [name,id] of Object.entries(pages)){
   const current=name===active;
   $(id).hidden=!current;
   $('nav'+name).setAttribute('aria-pressed',String(current));
 }
 if(active==='Profile')refreshProfile();
 window.scrollTo(0,0);
}
for(const name of Object.keys(pages))$('nav'+name).onclick=()=>showPage(name);
$('profileName').value=profile.name;
$('goalWeight').value=profile.weight??'';
$('goalDate').value=today();
setGoalInputs(today());

$('profileForm').onsubmit=event=>{
 event.preventDefault();
 const name=$('profileName').value.trim();
 const weight=$('goalWeight').value===''?null:Number($('goalWeight').value);
 if(saveProfile({...profile,name,weight},'profileStatus'))renderBrandGoal();
};
$('goalsForm').onsubmit=event=>{
 event.preventDefault();
 const day=$('goalDate').value;
 const calories=Number($('goalCalories').value);
 const steps=Number($('goalSteps').value);
 const sport=$('goalSport').value===''?null:Number($('goalSport').value);
 if(sport!=null&&(!Number.isInteger(sport)||sport<1||sport>7))return;
 if(!validDate(day)||!Number.isInteger(calories)||calories<1||calories>20000||!Number.isInteger(steps)||steps<1||steps>100000)return;
 if(profile.goals[day]&&!confirm('Remplacer les objectifs du '+longDay(day)+' ?'))return;
 if(saveProfile({...profile,goals:{...profile.goals,[day]:{calories,steps,sport}}},'goalStatus')){
   refreshProfile();
   render();
 }
};
const googleBridge=window.CapAndroid;
if(typeof googleBridge?.getGoogleAccount==='function'){
 const connect=$('googleSignIn'), disconnect=$('googleSignOut');
 window.capGoogleState=(account,message)=>{
   $('googleAccount').textContent=account||'Connexion facultative. Tes journées restent sur cet appareil.';
   $('googleStatus').textContent=message;
   connect.hidden=Boolean(account);
   disconnect.hidden=!account;
   connect.disabled=false;
   disconnect.disabled=false;
 };
 function requestAccountAction(action){
   connect.disabled=true;
   disconnect.disabled=true;
   $('googleStatus').textContent='';
   action();
 }
 connect.onclick=()=>requestAccountAction(()=>googleBridge.signInGoogle());
 disconnect.onclick=()=>requestAccountAction(()=>googleBridge.signOutGoogle());
 window.capGoogleState(googleBridge.getGoogleAccount(),'');
 $('googlePanel').hidden=false;
}
renderBrandGoal();
render();
})();
</script>
</body>
</html>
"""#
