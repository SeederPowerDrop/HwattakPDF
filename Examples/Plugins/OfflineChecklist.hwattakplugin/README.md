# Offline Study Checklist

권한 없는 첫 예제입니다. `capabilities: []`인 schema 1의 `showText`로 정적인 학습
체크리스트를 표시합니다. PDF를 열지 않아도 플러그인 메뉴에서 실행할 수 있습니다.
현재 ⇧⌘P 팔레트는 열린 PDF가 있어야 열리므로 빈 창에서는 메뉴를 사용하세요.

복사 후 식별자·작성자·이름을 자신의 값으로 바꾸고, `template`의 문장을 바꿉니다.
텍스트/페이지 토큰을 추가하면 해당 읽기 권한도 선언해야 합니다. 추가 파일은
manifest.json, README.md, LICENSE, LICENSE.md, icon.png만 허용됩니다.

이 예제는 PDF 읽기·수정, 클립보드, 네트워크 권한을 요청하지 않습니다.
MPL-2.0; 포함된 LICENSE를 확인하세요.

A zero-permission, schema 1 starter. It displays a static checklist through `showText`.
It works from the plugin menu without an open document. Customize the source manifest and
reinstall it through the manager. No compilation or JavaScript is required.
Tested against HwattakPDF's 2026-09-05 stabilization source. Replace the example identity
and add your own compatibility/support information before publishing. License: MPL-2.0.
