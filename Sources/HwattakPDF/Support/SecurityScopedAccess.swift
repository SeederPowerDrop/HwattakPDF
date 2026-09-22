// SPDX-License-Identifier: MPL-2.0

import Foundation

/// App Sandbox의 security-scoped URL 접근 수명을 RAII 방식으로 관리한다.
///
/// `startAccessing...`와 `stopAccessing...`는 반드시 짝이 맞아야 한다. 호출자가
/// 매 return/throw 경로마다 직접 stop하는 대신 이 객체를 강하게 들고 있으면,
/// Swift가 객체를 해제하는 `deinit`에서 정확히 한 번 권한을 반납한다.
/// URL이 scope 시작에 실패해도 `didStart`가 false라 잘못된 stop을 호출하지 않는다.
final class SecurityScopedAccess {
    let url: URL
    private let didStart: Bool

    /// 이 인스턴스가 살아 있는 동안만 해당 URL을 읽고 쓸 수 있다.
    init(url: URL) {
        self.url = url
        didStart = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if didStart {
            url.stopAccessingSecurityScopedResource()
        }
    }
}
