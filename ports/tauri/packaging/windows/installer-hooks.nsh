; Keep the ordinary ScanStudio shortcut unchanged and unarmed. This second,
; explicitly named shortcut opens the supervised owner-session launcher.
!macro NSIS_HOOK_POSTINSTALL
  ${If} $NoShortcutMode <> 1
    CreateShortCut "$SMPROGRAMS\${PRODUCTNAME} Hardware Session.lnk" "$INSTDIR\Start-ScanStudio-Hardware-Session.cmd" "" "$INSTDIR\${MAINBINARYNAME}.exe" 0
  ${EndIf}
!macroend

!macro NSIS_HOOK_POSTUNINSTALL
  !insertmacro IsShortcutTarget "$SMPROGRAMS\${PRODUCTNAME} Hardware Session.lnk" "$INSTDIR\Start-ScanStudio-Hardware-Session.cmd"
  Pop $0
  ${If} $0 = 1
    Delete "$SMPROGRAMS\${PRODUCTNAME} Hardware Session.lnk"
  ${EndIf}
!macroend
