import AppKit
import ImageIO
import Vision
import SwiftUI
import UniformTypeIdentifiers
import CastorCore

struct ArilsAISetupView: View {
    let palette: CastorPalette
    let openRigging: (NSImage?) -> Void
    @State private var step: Step = .referenceSet
    @State private var draft = ArilsAISettingsStore.current
    @State private var sourceImage: NSImage?
    @State private var poseHasTilt: Bool?
    @State private var poseGeneration=UUID()
    @State private var correctedImage: NSImage?
    @State private var imageImporterPresented=false
    @State private var externalGenerationConfirmation=false
    @State private var showPrompt=false
    @State private var imageError: String?
    @State private var imageTask: Task<Void,Never>?
    @State private var generation = ArilsAIAdjustmentCoordinator()
    @AppStorage("Castor.SettingsDisplayLanguage") private var language: SettingsDisplayLanguage = .systemDefault
    private func T(_ japanese: String,_ english: String) -> String {language == .japanese ? japanese : english}
    private var prompt: String { PoseCorrectionGuidance.prompt(language:language) }
    private var memoryGB: Int {Int((Double(ProcessInfo.processInfo.physicalMemory)/1_073_741_824).rounded())}

    var body: some View {
        VStack(spacing:16) {
            HStack {
                VStack(alignment:.leading,spacing:4) {
                    Label(T("AIで設定","Setting with AI"),systemImage:"wand.and.stars").font(.title2.weight(.semibold))
                    Text(T("画像と設定を準備します。AIの提案は、確認して承認するまで適用しません。","Prepare your image and settings. AI suggestions are applied only after your review and approval."))
                        .font(.callout).foregroundStyle(palette.secondaryText)
                }
                Spacer();Text("\(step.rawValue+1) / 5").font(.caption.monospaced())
            }
            Divider()
            ScrollView {
                VStack(alignment:.leading,spacing:16) {assistantBubble(question);stepContent}
                    .frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,4)
            }
            HStack {
                if step != .referenceSet {Button(T("戻る","Back")){stopGeneration();step=Step(rawValue:max(0,step.rawValue-1)) ?? .referenceSet}.disabled(generation.isWorking)}
                Spacer()
                Button(T("最初から","Start over")){stopGeneration();draft=ArilsAISettingsStore.current;sourceImage=nil;correctedImage=nil;poseHasTilt=nil;poseGeneration=UUID();showPrompt=false;imageError=nil;step = .referenceSet}
                    .buttonStyle(.plain).foregroundStyle(palette.secondaryText)
            }
        }
        .padding(24).frame(maxWidth:720,maxHeight:560)
        .castorGlassSurface(palette:palette,cornerRadius:24)
        .fileImporter(isPresented:$imageImporterPresented,allowedContentTypes:[.image]) { result in importReference(result) }
        .alert(T("Codexへ画像を送って生成しますか？","Send this image to Codex for generation?"),isPresented:$externalGenerationConfirmation) {
            Button(T("キャンセル","Cancel"),role:.cancel) {}
            Button(T("送信して生成","Send and generate")){generateImage()}
        } message: {
            Text(T("元画像のコピーを、設定済みのCodex接続からOpenAIへ送ります。アカウントの利用枠・料金が適用される場合があります。元画像は上書きせず、生成結果を確認してから使います。","A copy of the reference will be sent to OpenAI through your configured Codex connection. Your account's limits or charges may apply. The original is kept; you review the generated image before using it."))
        }
        .onDisappear {stopGeneration()}
    }
    private var question: String {
        switch step {
        case .referenceSet: T("何枚の画像で作りますか？まず正面側の画像を選びます。","How many views will you use? Choose the front reference first.")
        case .provider: T("顔マーカーをどのAIに確認してもらいますか？どれを選んでも手動補正できます。","Which AI should review the face markers? Manual adjustment is available with every choice.")
        case .posture:
            draft.provider == .codex
                ? T("姿勢を調整する機能は現在未実装なので姿勢がそのままで生成されます。そのまま生成することもできますが、姿勢を修正した画像を生成しますか？（任意）","Pose adjustment in the rig is not implemented, so the original pose is retained. You can build it as it is. Would you like to generate an image with a corrected pose? (Optional)")
                : T("姿勢を調整する機能は現在未実装なので姿勢がそのままで生成されます。そのまま生成することもできますが、姿勢を修正した画像を生成してからやり直しますか？（任意）","Pose adjustment in the rig is not implemented, so the original pose is retained. You can build it as it is. Would you like to generate a corrected image elsewhere and start again? (Optional)")
        case .underpaint: T("頭の裏側など、動くと見える部分をLaMaで補修しますか？","Use LaMa to repair hidden areas revealed by head motion?")
        case .review: T("この画像と設定で進めます。顔マーカーは次の画面で確認し、承認してから作成します。","Continue with this image and these settings. Review and approve the face markers in the next screen before building.")
        }
    }
    @ViewBuilder private var stepContent: some View {
        switch step {
        case .referenceSet:
            choice(title:T("正面の画像1枚","One front image"),detail:T("Standardで作成します。後からQualityの画像を追加できます。","Build Standard first; add a Quality reference later."),icon:"person.crop.rectangle") {
                draft.referenceSet = .frontOnly;imageImporterPresented=true
            }
            choice(title:T("正面＋斜め向きの画像","Front + three-quarter image"),detail:T("同じキャラクターが左右どちらかに約60°向いた画像を、後でQualityに追加します。","Add a matching reference turned about 60° left or right in Quality later."),icon:"rectangle.on.rectangle") {
                draft.referenceSet = .frontAndThreeQuarter;imageImporterPresented=true
            }
            if let imageError {Text(imageError).foregroundStyle(.orange)}
        case .provider:
            Text(T("外部AIを選んでも、送信の確認をするまで画像は端末の外へ出ません。","Choosing an external AI does not send the image until you confirm."))
                .font(.caption).foregroundStyle(palette.secondaryText)
            ForEach(ArilsAIProvider.allCases) {provider in
                choice(title:provider.label,detail:providerDescription(provider),icon:provider == .ollama ? "desktopcomputer":provider == .codex ? "chevron.left.forwardslash.chevron.right":"terminal") {
                    draft.provider=provider;showPrompt=false;imageError=nil;step = .posture
                }
            }
        case .posture: postureContent
        case .underpaint:
            Label(T("搭載メモリ：約\(memoryGB) GB","Installed memory: about \(memoryGB) GB"),systemImage:"memorychip").font(.callout.weight(.medium))
            Text(T("空きメモリではありません。LaMaは顔位置を判断せず、承認後に隠れる部分だけを補修します。","This is installed RAM, not free memory. LaMa repairs hidden regions after approval; it does not decide face positions."))
                .font(.caption).foregroundStyle(palette.secondaryText)
            choice(title:T("LaMaを使う","Use LaMa"),detail:T("任意のローカル補助ツールが必要です。失敗時は標準の補修へ戻ります。","Requires the optional local helper. If it fails, standard repair is used."),icon:"paintbrush.pointed") {draft.useLaMa=true;step = .review}
            choice(title:T("LaMaを使わない","Keep LaMa off"),detail:T("追加モデルなしで、Arilsの標準補修を使います。","Use standard Arils repair without an additional model."),icon:"cpu") {draft.useLaMa=false;step = .review}
        case .review:
            if let sourceImage {Image(nsImage:sourceImage).resizable().scaledToFit().frame(maxHeight:130)}
            summaryRow(T("画像","Images"),draft.referenceSet == .frontOnly ? T("正面1枚","Front only"):T("正面＋斜め向き","Front + three-quarter"))
            summaryRow(T("マーカー確認","Marker review"),draft.provider.label)
            summaryRow(T("隠れる部分の補修","Hidden-region repair"),draft.useLaMa ? T("LaMa（標準補修へ戻れます）","LaMa with fallback"):"Standard Arils")
            Text(T("リギングでArilsを開始し、顔の確認画面で「Suggest with AI」を選ぶと提案を受け取れます。画像を選び直さず、この画像を引き継ぎます。","Start Arils in Rigging, then choose “Suggest with AI” in face alignment. This image is carried over automatically."))
                .font(.callout)
            Button {
                ArilsAISettingsStore.current=draft;LaMaInpaintingSettingsStore.isEnabled=draft.useLaMa;openRigging(sourceImage)
            } label: {Label(T("設定を保存してリギングへ","Save setup and open Rigging"),systemImage:"checkmark.circle.fill").frame(maxWidth:.infinity)}
                .buttonStyle(.borderedProminent)
        }
    }
    @ViewBuilder private var postureContent: some View {
        if let sourceImage {Image(nsImage:sourceImage).resizable().scaledToFit().frame(maxHeight:155)}
        Text(poseHasTilt == true
            ? T("画像の体の軸が大きく傾いている可能性があります。判定は目安なので、画像を見て決めてください。","The body axis may be significantly tilted. This is only a hint; decide by reviewing the image.")
            : T("寝た姿勢や大きな傾きを直したい場合だけ「はい」を選んでください。姿勢を判定できない画像もあります。","Choose Yes only if you want to correct a lying pose or a pronounced tilt. Some images cannot be assessed reliably."))
            .font(.caption).foregroundStyle(palette.secondaryText)
        if generation.isWorking {
            ProgressView();Text(generation.status).font(.caption)
            Button(T("生成をキャンセル","Cancel generation")){stopGeneration()}
        } else if let correctedImage {
            Image(nsImage:correctedImage).resizable().scaledToFit().frame(maxHeight:210)
            Text(T("顔・服・手足を確認してください。生成画像は元のデザインから変わることがあります。","Check the face, clothes and limbs. Generated images may differ from the original design.")).font(.caption)
            HStack {
                Button(T("この生成画像を使う","Use this generated image")){sourceImage=correctedImage;poseHasTilt=nil;poseGeneration=UUID();self.correctedImage=nil;step = .underpaint}
                Button(T("元画像を使う","Use original image")){self.correctedImage=nil;step = .underpaint}
            }
        } else {
            HStack {
                Button(T("はい（任意）","Yes (optional)")) {
                    if draft.provider == .codex {externalGenerationConfirmation=true}else{showPrompt=true}
                }.buttonStyle(.borderedProminent)
                Button(T("いいえ、そのまま作成","No, use this pose")){step = .underpaint}
            }
        }
        if let approval=generation.pendingApproval {
            VStack(alignment:.leading,spacing:8) {
                Text(approval.title);Text(approval.detail).font(.caption.monospaced()).textSelection(.enabled)
                HStack {Button(T("拒否","Decline")){generation.resolvePendingApproval(approved:false)};Button(T("今回だけ許可","Allow once")){generation.resolvePendingApproval(approved:true)}}
            }
        }
        if let imageError {Text(imageError).font(.caption).foregroundStyle(.orange)}
        if showPrompt {
            Text(T("ChatGPTやQwen Image 2.1などの画像生成モデルへ元画像を添付し、次のプロンプトを入力してください。生成後に「生成した画像を読み込む」を押してやり直せます。","Attach the original image to an image generator such as ChatGPT or Qwen Image 2.1 and enter this prompt. Then choose “Load generated image” to restart with the result."))
            Text(prompt).font(.caption).textSelection(.enabled).padding(12).background(palette.readoutBackground,in:RoundedRectangle(cornerRadius:10))
            HStack {
                Button(T("プロンプトをコピー","Copy prompt")){NSPasteboard.general.clearContents();NSPasteboard.general.setString(prompt,forType:.string)}
                Button(T("生成した画像を読み込む","Load generated image")){imageImporterPresented=true}
                Button(T("元画像で続ける","Continue with original")){step = .underpaint}
            }
        }
    }
    private func importReference(_ result: Result<URL,Error>) {
        do {
            let url=try result.get();let access=url.startAccessingSecurityScopedResource();defer{if access{url.stopAccessingSecurityScopedResource()}}
            let size=(try url.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? Int.max
            guard size<=64*1_024*1_024,let source=CGImageSourceCreateWithURL(url as CFURL,[kCGImageSourceShouldCache:false] as CFDictionary),
                  let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
                  let width=properties[kCGImagePropertyPixelWidth] as? Int,let height=properties[kCGImagePropertyPixelHeight] as? Int,
                  width>0,height>0,width<=4096,height<=4096,
                  let cg=CGImageSourceCreateImageAtIndex(source,0,nil) else {throw ArilsAIAdjustmentError.imageEncodingFailed}
            sourceImage=NSImage(cgImage:cg,size:.zero);correctedImage=nil;imageError=nil;poseHasTilt=nil
            let token=UUID();poseGeneration=token
            Task { @MainActor in
                let hint=await Task.detached(priority:.userInitiated) { () -> Bool? in
                    let request=VNDetectHumanBodyPoseRequest()
                    do {
                        try VNImageRequestHandler(cgImage:cg,options:[:]).perform([request])
                        guard let poses=request.results,poses.count==1,
                              let neck=try? poses[0].recognizedPoint(.neck),let root=try? poses[0].recognizedPoint(.root),
                              neck.confidence>=0.4,root.confidence>=0.4 else{return nil}
                        let dx=abs(neck.location.x-root.location.x),dy=abs(neck.location.y-root.location.y)
                        guard dx*dx+dy*dy>=0.0025 else{return nil}
                        return dx>dy*0.7
                    } catch{return nil}
                }.value
                if poseGeneration==token {poseHasTilt=hint}
            }
            if step == .referenceSet {step = .provider}else{showPrompt=false;step = .posture}
        } catch CocoaError.userCancelled {} catch {imageError=error.localizedDescription}
    }
    private func generateImage() {
        guard let sourceImage else{return}
        stopGeneration();imageError=nil;showPrompt=false
        let brief=prompt
        imageTask=Task { @MainActor in
            do {let image=try await generation.generateUprightImage(image:sourceImage,prompt:brief);try Task.checkCancellation();correctedImage=image}
            catch is CancellationError {}
            catch {imageError=error.localizedDescription;showPrompt=true}
        }
    }
    private func stopGeneration(){imageTask?.cancel();imageTask=nil;generation.cancel()}
    private func providerDescription(_ provider: ArilsAIProvider) -> String {
        switch provider {
        case .ollama: T("画像対応モデルで端末内の確認を行います。LM Studioが利用できれば優先し、Ollamaへ切り替えられます。","Review locally with a vision model. Available LM Studio vision models are preferred; Ollama is the fallback.")
        case .codex: T("設定済みのCodex接続を使います。確認後、画像が外部で処理される場合があります。","Use your configured Codex connection. After confirmation, the image may be processed externally.")
        case .claudeCode: T("設定済みのClaude Code接続を使います。確認後、画像が外部で処理される場合があります。","Use your configured Claude Code connection. After confirmation, the image may be processed externally.")
        }
    }
    private func assistantBubble(_ text: String) -> some View {
        HStack(alignment:.top,spacing:10) {Image(systemName:"sparkles").foregroundStyle(palette.accent);Text(text).fixedSize(horizontal:false,vertical:true);Spacer(minLength:20)}
            .padding(14).background(palette.readoutBackground.opacity(0.88),in:RoundedRectangle(cornerRadius:16))
    }
    private func choice(title:String,detail:String,icon:String,action:@escaping()->Void) -> some View {
        Button(action:action) {HStack(spacing:12){Image(systemName:icon).font(.title3).frame(width:30);VStack(alignment:.leading,spacing:3){Text(title).fontWeight(.semibold);Text(detail).font(.caption).foregroundStyle(palette.secondaryText).fixedSize(horizontal:false,vertical:true)};Spacer();Image(systemName:"chevron.right").foregroundStyle(palette.secondaryText)}.padding(14).contentShape(Rectangle())}
            .buttonStyle(.plain).background(palette.readoutBackground.opacity(0.76),in:RoundedRectangle(cornerRadius:14))
            .overlay{RoundedRectangle(cornerRadius:14).stroke(palette.readoutBorder,lineWidth:1)}
    }
    private func summaryRow(_ title:String,_ value:String) -> some View {HStack{Text(title).foregroundStyle(palette.secondaryText);Spacer();Text(value).fontWeight(.medium)}}
    private enum Step: Int {case referenceSet,provider,posture,underpaint,review}
}
