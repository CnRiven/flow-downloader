import SwiftUI
import AppKit
import FlowCore

enum Palette {
    static let ink = Color(red: 0.12, green: 0.19, blue: 0.18)
    static let muted = Color(red: 0.48, green: 0.52, blue: 0.50)
    static let green = Color(red: 0.14, green: 0.42, blue: 0.32)
    static let mint = Color(red: 0.85, green: 0.93, blue: 0.88)
    static let paper = Color(red: 0.97, green: 0.97, blue: 0.95)
    static let line = Color.black.opacity(0.07)
}

struct ActionStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 17).padding(.vertical, 11)
            .foregroundStyle(prominent ? .white : Palette.ink)
            .background(prominent ? Palette.green : Color.white, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(prominent ? .clear : Palette.line))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                topbar
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        intro
                        quickAdd
                        HStack(spacing: 14) {
                            stat("正在下载", value: model.activeCount, icon: "arrow.down", color: Palette.green)
                            stat("已完成", value: model.completedCount, icon: "checkmark", color: Palette.green)
                            stat("已暂停", value: model.pausedCount, icon: "pause", color: Palette.muted)
                        }
                        taskList
                    }.padding(32)
                }
                footer
            }.background(Palette.paper)
        }.foregroundStyle(Palette.ink)
            .sheet(isPresented: $model.showingNew) { NewDownloadView().environmentObject(model) }
            .sheet(isPresented: $model.showingSettings) { SettingsView().environmentObject(model) }
            .sheet(item: $model.logJob) { job in LogView(job: job).environmentObject(model) }
            .alert("需要处理", isPresented: Binding(get: { model.error != nil && !model.showingNew }, set: { if !$0 { model.error = nil } })) {
                Button("知道了") { model.error = nil }
            } message: { Text(model.error ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "arrow.down.to.line.compact").font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Palette.ink).frame(width: 44, height: 44).background(Palette.mint, in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 2) {
                    Text("拾流").font(.system(size: 23, weight: .semibold))
                    Text("FLOW DOWNLOADER").font(.system(size: 8, weight: .medium)).tracking(1.6).foregroundStyle(.white.opacity(0.45))
                }
            }.padding(.top, 34).padding(.bottom, 42)
            Text("资料库").font(.system(size: 10, weight: .medium)).tracking(2).foregroundStyle(.white.opacity(0.35)).padding(.leading, 12).padding(.bottom, 14)
            nav("全部任务", icon: "square.grid.2x2", count: model.jobs.count)
            nav("下载中", icon: "arrow.down.circle", count: model.jobs.filter { [.queued, .downloading, .processing, .paused].contains($0.status) }.count)
            nav("已完成", icon: "checkmark.circle", count: model.completedCount)
            Spacer()
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "leaf").font(.system(size: 21)).foregroundStyle(Palette.mint)
                Text("让喜欢的内容，\n留在你的设备里。").font(.system(size: 13, weight: .medium)).lineSpacing(6).foregroundStyle(.white.opacity(0.8))
                Text("本地下载 · 自由收藏").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
            }.padding(17).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 13)).padding(.bottom, 24)
            Button { model.showingSettings = true } label: {
                Label("偏好设置", systemImage: "slider.horizontal.3").font(.system(size: 13)).foregroundStyle(.white.opacity(0.7)).padding(12)
            }.buttonStyle(.plain)
            HStack { Circle().fill(model.paths.downloader == nil ? .orange : Palette.mint).frame(width: 5, height: 5); Text(model.paths.downloader == nil ? "下载引擎未就绪" : "下载引擎已就绪").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4)) }.padding(12)
        }.padding(.horizontal, 18).padding(.bottom, 18).frame(width: 205).background(Palette.ink).foregroundStyle(.white)
    }

    private func nav(_ title: String, icon: String, count: Int) -> some View {
        Button { model.selectedSection = title } label: {
            HStack(spacing: 11) {
                Image(systemName: icon).font(.system(size: 16)).frame(width: 19)
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer()
                Text("\(count)").font(.system(size: 10, weight: .medium, design: .monospaced)).opacity(0.6)
            }.padding(12).foregroundStyle(model.selectedSection == title ? Palette.ink : .white.opacity(0.65))
                .background(model.selectedSection == title ? Palette.mint : .clear, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).padding(.bottom, 5)
    }

    private var topbar: some View {
        HStack {
            Text("我的工作空间").font(.system(size: 11)).foregroundStyle(Palette.muted)
            Text("/").foregroundStyle(Palette.line)
            Text(model.selectedSection).font(.system(size: 11, weight: .medium))
            Spacer()
            Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
            TextField("搜索任务", text: $model.search).textFieldStyle(.plain).font(.system(size: 12)).frame(width: 140)
            Button { NSWorkspace.shared.open(URL(fileURLWithPath: model.directory)) } label: { Image(systemName: "folder").font(.system(size: 15)) }.buttonStyle(.plain).help("打开下载文件夹")
        }.padding(.horizontal, 32).frame(height: 62).background(.white.opacity(0.7)).overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
    }

    private var intro: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.selectedSection).font(.system(size: 29, weight: .semibold)).tracking(-0.5)
                Text("一段链接，收藏每一份灵感。").font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            Spacer()
            Button { model.showingNew = true } label: { Label("新建下载", systemImage: "plus") }.buttonStyle(ActionStyle(prominent: true)).keyboardShortcut("n")
        }
    }

    private var quickAdd: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Text("下一份灵感，从这里开始").font(.system(size: 16, weight: .semibold))
                Spacer()
                Text("PASTE. DOWNLOAD. KEEP.").font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(1.5).foregroundStyle(Palette.green.opacity(0.65))
            }
            HStack(spacing: 12) {
                Image(systemName: "link").font(.system(size: 16)).foregroundStyle(Palette.green)
                TextField("粘贴视频链接，支持 YouTube、Bilibili 等站点", text: $model.urlInput).textFieldStyle(.plain).font(.system(size: 12)).onSubmit { model.showingNew = true }
                Button { model.pasteLink() } label: { Image(systemName: "doc.on.clipboard").foregroundStyle(Palette.muted) }.buttonStyle(.plain).help("粘贴链接")
                Button("解析链接") { model.showingNew = true; model.inspect() }.buttonStyle(ActionStyle(prominent: true)).disabled(model.urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(9).padding(.leading, 7).background(.white, in: RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 15) {
                Label("画质自由选择", systemImage: "4k.tv")
                Label("视频 / 音频", systemImage: "waveform")
                Label("断点续传", systemImage: "arrow.clockwise")
            }.font(.system(size: 10)).foregroundStyle(Palette.green.opacity(0.8))
        }.padding(23).background(Palette.mint.opacity(0.55), in: RoundedRectangle(cornerRadius: 17)).overlay(RoundedRectangle(cornerRadius: 17).stroke(Palette.green.opacity(0.08)))
    }

    private func stat(_ title: String, value: Int, icon: String, color: Color) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.system(size: 11)).foregroundStyle(Palette.muted)
                Text("\(value)").font(.system(size: 27, weight: .medium, design: .rounded))
            }
            Spacer()
            Image(systemName: icon).font(.system(size: 17, weight: .medium)).foregroundStyle(color).frame(width: 38, height: 38).background(Palette.paper, in: RoundedRectangle(cornerRadius: 12))
        }.padding(19).frame(maxWidth: .infinity).background(.white, in: RoundedRectangle(cornerRadius: 13)).overlay(RoundedRectangle(cornerRadius: 13).stroke(Palette.line))
    }

    private var taskList: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Text("下载列表").font(.system(size: 15, weight: .semibold))
                Text("\(model.filteredJobs.count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted).padding(.horizontal, 8).padding(.vertical, 4).background(.white, in: Capsule())
                Spacer()
                Text("最新添加优先 · 同时下载 2 个任务").font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            if model.filteredJobs.isEmpty {
                VStack(spacing: 13) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 22).fill(Palette.paper).frame(width: 78, height: 78).rotationEffect(.degrees(-8))
                        Image(systemName: model.search.isEmpty ? "tray.and.arrow.down" : "magnifyingglass").font(.system(size: 29, weight: .light)).foregroundStyle(Palette.green)
                    }.padding(.bottom, 4)
                    Text(model.search.isEmpty ? "你的收藏，从第一段链接开始" : "没有找到匹配的任务").font(.system(size: 14, weight: .medium))
                    Text(model.search.isEmpty ? "把想保存的视频链接粘贴到上方，剩下的交给拾流。" : "换一个关键词试试。").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    if model.search.isEmpty { Button("添加第一个下载  ↗") { model.showingNew = true }.buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.green).padding(.top, 7) }
                }.frame(maxWidth: .infinity).frame(height: 240).background(.white, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.line))
            } else {
                LazyVStack(spacing: 10) { ForEach(model.filteredJobs) { job in JobRow(job: job).environmentObject(model) } }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "externaldrive").font(.system(size: 10))
            Text(model.directory).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text("拾流 1.0").tracking(1)
            Text("·  Powered by yt-dlp")
        }.font(.system(size: 9)).foregroundStyle(Palette.muted).padding(.horizontal, 32).frame(height: 37).overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
    }
}

struct JobRow: View {
    @EnvironmentObject var model: AppModel
    let job: DownloadJob
    var body: some View {
        HStack(spacing: 17) {
            ZStack {
                RoundedRectangle(cornerRadius: 9).fill(Palette.mint.opacity(0.5))
                Image(systemName: job.quality == .audio ? "waveform" : "play.rectangle").font(.system(size: 25, weight: .light)).foregroundStyle(Palette.green)
                if let image = job.thumbnail, let url = URL(string: image), url.scheme == "https" || url.scheme == "http" {
                    AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Color.clear }
                }
            }.frame(width: 92, height: 65).clipped().cornerRadius(9)
            VStack(alignment: .leading, spacing: 8) {
                Text(job.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                HStack(spacing: 8) {
                    Text(URL(string: job.url)?.host ?? "视频链接")
                    Text("·")
                    Text(job.quality.label)
                    Spacer()
                    Text(job.status.label).foregroundStyle(job.status == .failed ? .red : Palette.green)
                }.font(.system(size: 10)).foregroundStyle(Palette.muted)
                if job.status.active || job.status == .paused {
                    ProgressView(value: job.progress).tint(Palette.green)
                    HStack {
                        Text(job.speed); Text(job.eta); Spacer(); Text("\(Int(job.progress * 100))%")
                    }.font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.muted)
                }
                if let error = job.error { Text(error).font(.system(size: 10)).foregroundStyle(.red).lineLimit(2).textSelection(.enabled) }
            }
            Group {
                if job.status.active || job.status == .queued {
                    Button { model.pause(job.id) } label: { Image(systemName: "pause.fill") }.help("暂停下载")
                } else if job.status == .completed {
                    Button { model.reveal(job) } label: { Image(systemName: "folder") }.help("在 Finder 中显示")
                } else {
                    Button { model.resume(job.id) } label: { Image(systemName: "play.fill") }.help("继续 / 重试")
                }
            }.buttonStyle(.plain).foregroundStyle(Palette.green).frame(width: 23)
            Menu {
                Button("查看日志") { model.logJob = job }
                Button("复制链接") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(job.url, forType: .string) }
                Button("在 Finder 中显示") { model.reveal(job) }
                Divider()
                Button("移除记录（保留文件）", role: .destructive) { model.remove(job.id) }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 22)
        }.padding(17).background(.white, in: RoundedRectangle(cornerRadius: 13)).overlay(RoundedRectangle(cornerRadius: 13).stroke(Palette.line))
    }
}

struct NewDownloadView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                VStack(alignment: .leading, spacing: 7) {
                    Text("收藏一份新灵感").font(.system(size: 24, weight: .semibold))
                    Text("粘贴链接，选择你喜欢的保存方式。").font(.system(size: 12)).foregroundStyle(Palette.muted)
                }; Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 20)).foregroundStyle(Palette.muted) }.buttonStyle(.plain)
            }
            HStack {
                TextField("https://…", text: $model.urlInput).textFieldStyle(.roundedBorder).onSubmit { model.inspect() }
                Button("粘贴") { model.pasteLink() }.buttonStyle(ActionStyle())
                Button(model.inspecting ? "解析中…" : "解析") { model.inspect() }.buttonStyle(ActionStyle()).disabled(model.inspecting)
            }
            if model.inspecting { HStack { ProgressView().controlSize(.small); Text("正在获取视频信息…").font(.system(size: 12)).foregroundStyle(Palette.muted) } }
            if let info = model.info {
                HStack(spacing: 14) {
                    Image(systemName: "play.rectangle.fill").font(.system(size: 32)).foregroundStyle(Palette.green)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(info.title).font(.system(size: 14, weight: .semibold)).lineLimit(3)
                        Text([info.uploader, info.durationLabel, info.extractor].compactMap { $0 }.joined(separator: "  ·  ")).font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Palette.mint.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("保存格式").font(.system(size: 12, weight: .semibold))
                Picker("保存格式", selection: $model.quality) { ForEach(Quality.allCases) { Text($0.label).tag($0) } }.pickerStyle(.segmented).labelsHidden()
                Text("清晰度为上限，实际可选画质取决于视频源。").font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            HStack {
                Image(systemName: "folder").foregroundStyle(Palette.green)
                Text(model.directory).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                Spacer(); Button("更改") { model.chooseDirectory() }.buttonStyle(.plain).foregroundStyle(Palette.green)
            }.padding(14).background(.white, in: RoundedRectangle(cornerRadius: 10))
            HStack { Text("每次添加一个视频；纯播放列表链接仅保存第一项。").font(.system(size: 10)).foregroundStyle(Palette.muted); Spacer() }
            HStack { Spacer(); Button("取消") { dismiss() }.buttonStyle(ActionStyle()); Button("加入下载队列") { model.add() }.buttonStyle(ActionStyle(prominent: true)).disabled(model.urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.inspecting) }
        }.padding(30).frame(width: 620).background(Palette.paper).foregroundStyle(Palette.ink)
            .alert("需要处理", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("知道了") { model.error = nil }
            } message: { Text(model.error ?? "") }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("偏好设置").font(.system(size: 24, weight: .semibold))
            VStack(alignment: .leading, spacing: 10) {
                Text("下载位置").font(.headline)
                HStack { Text(model.directory).font(.system(size: 11)).textSelection(.enabled); Spacer(); Button("选择…") { model.chooseDirectory() } }
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("下载引擎").font(.headline)
                dependency("yt-dlp", path: model.paths.downloader)
                dependency("FFmpeg", path: model.paths.ffmpeg)
                dependency("Deno（YouTube 脚本运行时）", path: model.paths.runtime)
                Text("缺少组件时，在终端运行：").font(.system(size: 11)).foregroundStyle(Palette.muted)
                Text("brew install yt-dlp ffmpeg deno").font(.system(size: 12, design: .monospaced)).textSelection(.enabled).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.white, in: RoundedRectangle(cornerRadius: 8))
                HStack { Button("重新检测") { model.refreshEngine() }; Spacer(); Link("yt-dlp 项目 ↗", destination: URL(string: "https://github.com/yt-dlp/yt-dlp")!) }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("登录状态").font(.headline)
                Picker("读取浏览器 Cookie", selection: $model.browser) {
                    Text("不读取（默认）").tag("")
                    Text("Safari").tag("safari"); Text("Chrome").tag("chrome")
                    Text("Firefox").tag("firefox"); Text("Edge").tag("edge")
                }
                Text("仅在你选择后，由本机 yt-dlp 读取已登录浏览器的 Cookie。新任务使用此设置；系统可能要求浏览器或钥匙串访问授权。").font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            Text("拾流 Flow 1.0 · GPL-3.0-or-later\n下载能力由 yt-dlp 提供，站点适配以引擎实际支持为准。").font(.system(size: 10)).foregroundStyle(Palette.muted)
            HStack { Spacer(); Button("完成") { dismiss() }.buttonStyle(ActionStyle(prominent: true)) }
        }.padding(30).frame(width: 570).background(Palette.paper).foregroundStyle(Palette.ink)
    }
    private func dependency(_ name: String, path: String?) -> some View {
        HStack(alignment: .top) {
            Image(systemName: path == nil ? "exclamationmark.circle" : "checkmark.circle.fill").foregroundStyle(path == nil ? .orange : Palette.green)
            VStack(alignment: .leading, spacing: 3) { Text(name).font(.system(size: 12, weight: .medium)); Text(path ?? "未检测到").font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted).textSelection(.enabled) }
        }
    }
}

struct LogView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    let job: DownloadJob
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("任务日志").font(.title2).bold()
            Text(job.title).font(.headline).lineLimit(2)
            ScrollView { Text(((model.logs[job.id] ?? []) + [model.jobs.first(where: { $0.id == job.id })?.error ?? ""]).joined(separator: "\n")).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 330)
            HStack { Text("日志仅保留在本次运行内。").font(.caption).foregroundStyle(.secondary); Spacer(); Button("关闭") { dismiss() }.buttonStyle(ActionStyle(prominent: true)) }
        }.padding(25).frame(width: 650).background(Palette.paper)
    }
}
