// SPDX-License-Identifier: MPL-2.0

import AppKit
import SwiftUI

enum AboutContent {
    static let sceneID = "about-hwattakpdf"
    static let imageResourceName = "AboutAuthor-SeederPowerDrop-UserProvided"
    static let imageResourceExtension = "jpg"

    // Keep the original Korean wording as the fallback and source of truth,
    // while presenting a reviewed translation in the selected app language.
    static let introductionParagraphs = [
        "모 PDF 프로그램을 유로로 구입해서 사용하고 있는데 이제는 기본적인 기능 조차 구독으로 바뀌어서 화딱지나서 바이브 코딩으로 만들었습니다.",
        "그 회사도 먹고 살기위해서 어쩔 수 없는 것을 알지만 기존에 유로 구입자에게 너무한 조치라서 만들었습니다.",
        "많은 사람들이 편리하게 사용했으면 합니다.",
        "그리고 평생 무료로 최대한 지원해드리며 소정의 tip만 받도록 하겠습니다.",
        "그리고 ERW FWS WRG"
    ]

    static let introductionLocalizationKeys = [
        "about.introduction.1",
        "about.introduction.2",
        "about.introduction.3",
        "about.introduction.4",
        "about.introduction.5"
    ]

    static var localizedIntroductionParagraphs: [String] {
        zip(introductionLocalizationKeys, introductionParagraphs).map { key, fallback in
            L10n.string(key, defaultValue: fallback)
        }
    }

    static var supportTitle: String {
        L10n.string(
            "about.support.title",
            defaultValue: "HwattakPDF를 계속 무료로 만드는 힘"
        )
    }

    static var supportDetail: String {
        L10n.string(
            "about.support.detail",
            defaultValue: "HwattakPDF에는 구독료와 광고가 없습니다. 자발적인 후원은 무료 개발과 유지보수를 계속할 수 있는 유일한 지원 수단입니다."
        )
    }

    static let githubURL = validatedExternalURL(
        "https://github.com/SeederPowerDrop/HwattakPDF"
    )
    static let supportURL = validatedExternalURL("https://buymeacoffee.com/master_chief")

    /// About links must always leave the app through an ordinary web origin.
    /// User-info is rejected so a displayed host cannot conceal credentials or
    /// a misleading destination.
    static func validatedExternalURL(_ rawValue: String) -> URL? {
        guard
            rawValue.count <= 2_048,
            let components = URLComponents(string: rawValue),
            let scheme = components.scheme?.lowercased(),
            scheme == "https" || scheme == "http",
            let host = components.host,
            !host.isEmpty,
            components.user == nil,
            components.password == nil,
            let url = components.url
        else {
            return nil
        }
        return url
    }

    static func authorImage(bundle: Bundle = .main) -> NSImage? {
        if let bundledURL = bundle.url(
            forResource: imageResourceName,
            withExtension: imageResourceExtension
        ), let image = NSImage(contentsOf: bundledURL) {
            return image
        }

        #if DEBUG
        let sourceURL = sourceResourcesDirectory
            .appendingPathComponent(imageResourceName)
            .appendingPathExtension(imageResourceExtension)
        return NSImage(contentsOf: sourceURL)
        #else
        return nil
        #endif
    }

    #if DEBUG
    private static var sourceResourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
    }
    #endif
}

struct AboutView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.colorScheme) private var colorScheme

    private let authorImage: NSImage?

    private var theme: HwattakPDFTheme { HwattakPDFTheme(colorScheme: colorScheme) }
    private var canvas: Color {
        colorScheme == .dark ? theme.canvas : Color(red: 0.95, green: 0.94, blue: 0.86)
    }
    private var bodyText: Color {
        colorScheme == .dark ? theme.primaryText : .black
    }

    init(authorImage: NSImage? = AboutContent.authorImage()) {
        self.authorImage = authorImage
    }

    var body: some View {
        VStack(spacing: 0) {
            classicTitleBar
            mainContent
            bottomBar
        }
        .frame(width: 840, height: 690)
        .background(canvas)
        .overlay {
            Rectangle()
                .stroke(
                    colorScheme == .dark ? theme.border : Color(red: 0.35, green: 0.36, blue: 0.37),
                    lineWidth: 2
                )
        }
        // Keep the classic dialog layout while following the app's appearance.
        .accessibilityElement(children: .contain)
    }

    private var classicTitleBar: some View {
        HStack(spacing: 12) {
            Text(L10n.string("about.title", defaultValue: "HwattakPDF 정보"))
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)

            Spacer(minLength: 12)

            Button {
                dismissWindow(id: AboutContent.sceneID)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 21, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 34)
                    .background(
                        LinearGradient(
                            colors: [
                                Color(red: 1.0, green: 0.42, blue: 0.31),
                                Color(red: 0.78, green: 0.08, blue: 0.05)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.white.opacity(0.9), lineWidth: 2)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .shadow(color: .black.opacity(0.55), radius: 0, x: 2, y: 2)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help(L10n.string("about.close", defaultValue: "닫기"))
            .accessibilityLabel(L10n.string("about.close", defaultValue: "닫기"))
        }
        .padding(.horizontal, 12)
        .frame(height: 58)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.00, green: 0.28, blue: 0.88),
                    Color(red: 0.18, green: 0.55, blue: 0.98)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.white.opacity(0.75))
                .frame(height: 2)
        }
    }

    private var mainContent: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 28) {
                authorPortrait

                VStack(alignment: .leading, spacing: 14) {
                    ForEach(
                        Array(AboutContent.localizedIntroductionParagraphs.enumerated()),
                        id: \.offset
                    ) { _, paragraph in
                        Text(paragraph)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    supportCard
                        .padding(.top, 4)

                    githubRow
                }
                .font(.system(size: 17.5, weight: .regular, design: .default))
                .foregroundStyle(bodyText)
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 34)
            .padding(.top, 30)
            .padding(.bottom, 22)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var authorPortrait: some View {
        if let authorImage {
            Image(nsImage: authorImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 178, height: 178)
                .background(.white)
                .overlay(alignment: .topLeading) {
                    Rectangle()
                        .stroke(Color(red: 0.47, green: 0.47, blue: 0.49), lineWidth: 4)
                }
                .shadow(color: .white.opacity(0.95), radius: 0, x: 2, y: 2)
                .accessibilityLabel(
                    L10n.string(
                        "about.image_accessibility",
                        defaultValue: "제작자가 제공한 흑백 캐릭터 그림"
                    )
                )
        } else {
            ZStack {
                Color.white
                Image(systemName: "person.crop.square")
                    .font(.system(size: 72, weight: .light))
                    .foregroundStyle(Color.gray)
            }
            .frame(width: 178, height: 178)
            .overlay {
                Rectangle()
                    .stroke(Color(red: 0.47, green: 0.47, blue: 0.49), lineWidth: 4)
            }
            .accessibilityLabel(
                L10n.string("about.image_unavailable", defaultValue: "소개 이미지를 불러오지 못했습니다")
            )
        }
    }

    private var supportCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label(AboutContent.supportTitle, systemImage: "heart.fill")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(
                    colorScheme == .dark ? theme.warning : Color(red: 0.42, green: 0.08, blue: 0.04)
                )

            Text(AboutContent.supportDetail)
                .font(.system(size: 15.5, weight: .medium))
                .foregroundStyle(bodyText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(15)
        .background(colorScheme == .dark ? theme.panel : Color(red: 1.0, green: 0.96, blue: 0.72))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    colorScheme == .dark ? theme.warning.opacity(0.55) : Color(red: 0.42, green: 0.34, blue: 0.12),
                    lineWidth: 2
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var githubRow: some View {
        if let githubURL = AboutContent.githubURL {
            Link(destination: githubURL) {
                Label(
                    L10n.string(
                        "about.github",
                        defaultValue: "GitHub · github.com/SeederPowerDrop/HwattakPDF"
                    ),
                    systemImage: "chevron.left.forwardslash.chevron.right"
                )
            }
            .font(.system(size: 15.5, weight: .medium))
            .foregroundStyle(colorScheme == .dark ? theme.steel : Color(red: 0.0, green: 0.25, blue: 0.92))
            .underline()
            .help(githubURL.absoluteString)
            .environment(\.layoutDirection, .leftToRight)
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(colorScheme == .dark ? theme.border : Color(red: 0.53, green: 0.53, blue: 0.55))
                .frame(height: 1)

            HStack(spacing: 16) {
                if let supportURL = AboutContent.supportURL {
                    Link(destination: supportURL) {
                        Label(
                            L10n.string(
                                "about.support",
                                defaultValue: "HwattakPDF 후원하기"
                            ),
                            systemImage: "cup.and.saucer.fill"
                        )
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                    }
                    .buttonStyle(ClassicSupportButtonStyle())
                    .help(supportURL.absoluteString)
                }

                Button {
                    dismissWindow(id: AboutContent.sceneID)
                } label: {
                    Text(L10n.string("about.confirm", defaultValue: "확인"))
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(bodyText)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .buttonStyle(ClassicWindowsButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 17)
        }
        .background(canvas)
        // Keep the classic confirmation area from being compressed when the
        // surrounding environment uses right-to-left layout direction.
        .frame(maxWidth: .infinity, minHeight: 79, idealHeight: 79)
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(1)
    }
}

private struct ClassicSupportButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                LinearGradient(
                    colors: configuration.isPressed
                        ? [
                            Color(red: 0.95, green: 0.62, blue: 0.06),
                            Color(red: 1.0, green: 0.84, blue: 0.18)
                        ]
                        : [
                            Color(red: 1.0, green: 0.88, blue: 0.20),
                            Color(red: 1.0, green: 0.67, blue: 0.08)
                        ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(red: 0.32, green: 0.24, blue: 0.08), lineWidth: 2)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(color: .black.opacity(0.45), radius: 0, x: 3, y: 4)
            .offset(y: configuration.isPressed ? 2 : 0)
    }
}

private struct ClassicWindowsButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    private var theme: HwattakPDFTheme { HwattakPDFTheme(colorScheme: colorScheme) }

    private func gradientColors(isPressed: Bool) -> [Color] {
        if colorScheme == .dark {
            return isPressed ? [theme.panel, theme.card] : [theme.card, theme.panel]
        }
        return isPressed
            ? [Color(red: 0.84, green: 0.83, blue: 0.77), .white]
            : [.white, Color(red: 0.88, green: 0.87, blue: 0.79)]
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                LinearGradient(
                    colors: gradientColors(isPressed: configuration.isPressed),
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(colorScheme == .dark ? theme.card : .white, lineWidth: 3)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        colorScheme == .dark ? theme.border : Color(red: 0.54, green: 0.54, blue: 0.57),
                        lineWidth: 2
                    )
                    .padding(2)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(color: .black.opacity(0.45), radius: 0, x: 3, y: 4)
            .offset(y: configuration.isPressed ? 2 : 0)
    }
}
