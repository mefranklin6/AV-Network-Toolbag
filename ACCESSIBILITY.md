# Accessibility

AV Network Toolbag is designed to work with Windows keyboard navigation,
accessibility text scaling, High Contrast mode, and assistive technologies that
consume Flutter's Windows UI Automation semantics.

This document is a release-testing checklist. It is not a claim of formal
conformance and is not an Accessibility Conformance Report (ACR).

## Release checklist

Test the release build, not only `flutter run`.

### Keyboard

- Complete every workflow using Tab, Shift+Tab, arrow keys, Space, Enter, and
  Escape without using a pointer.
- Confirm focus order follows the visual and reading order.
- Confirm every focused control has a clearly visible indicator in light,
  dark, and Windows High Contrast modes.
- Confirm focus remains inside an open modal until the modal is closed and that
  every modal has a keyboard-operable close or cancel action.
- Confirm F5 refreshes adapters and Ctrl+D cycles the appearance setting.

### Screen reader and UI Automation

- Test with a current NVDA release on Windows.
- Confirm the application and each modal announces its name.
- Confirm controls expose an understandable name, role, enabled state, checked
  or selected state, and current value where applicable.
- Confirm adapter rows, status cards, scan results, mDNS results, and DHCP
  leases are announced with their column or field meaning.
- Confirm loading, progress, completion, error, and copied/exported status
  messages are announced without moving keyboard focus.

### Visual presentation

- Test light, dark, and Windows High Contrast modes.
- Verify text contrast is at least 4.5:1 and component/focus indicators are at
  least 3:1 against adjacent colors.
- Test Windows text size at 100%, 150%, and 200%.
- Resize the window from the normal launch size down to the 640 by 520 minimum
  and confirm controls reflow without being clipped or requiring horizontal
  scrolling, except for data tables whose columns require it.
- Confirm information is never communicated by color alone.

### Interaction and timing

- Confirm all pointer actions have keyboard equivalents.
- Confirm compact controls remain at least 24 by 24 logical pixels and do not
  overlap adjacent targets.
- Confirm indeterminate activity has a programmatic label and long operations
  expose status or progress.
- Confirm no essential workflow depends on animation, hover, or a timed input.

## Reference standards

- [WCAG 2.2 Quick Reference](https://www.w3.org/WAI/WCAG22/quickref/)
- [Section 508 software testing guidance](https://www.section508.gov/test/)
- [Creating an ACR using a VPAT](https://www.section508.gov/sell/how-to-create-acr-with-vpat/)

Record the application version, Windows version, display scaling, text size,
assistive technology and version, test results, and any exceptions when using
this checklist as evidence for an ACR.
