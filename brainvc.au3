; BrAiNVC - optical data channel, step 2a (loopback + PNG export for video)
; Usage:  brainvc.au3 enc     = live encoder (shows frames in a window)
;         brainvc.au3 scan    = scanner (drag the red frame over the encoder window / video player)
;         brainvc.au3 export  = render PNG frames + make_video.bat (ffmpeg), no screen recording needed
;         no argument         = chooser
; Scanner keys: PgUp/PgDn = resize frame (cell size +/- 1px), Home = save partial, End = quit
#include <GDIPlus.au3>
#include <ScreenCapture.au3>
#include <WinAPI.au3>
#include <GUIConstantsEx.au3>
#include <WindowsConstants.au3>
#include <Math.au3>

DllCall("user32.dll", "bool", "SetProcessDPIAware")

; ---- frame layout (16:9 grid, COLS*ROWS must be divisible by 8) -------
Global Const $COLS = 96, $ROWS = 54
Global Const $NCELLS = $COLS * $ROWS       ; 5184 cells = 5184 bits
Global Const $NBYTES = Int($NCELLS / 8)    ; 648 bytes per frame
Global Const $HDR = 7                      ; counter(2) len(2) flags(1) crc(2)
Global Const $PAY = $NBYTES - $HDR         ; 641 payload bytes per frame
Global Const $BORDER = 6

; ---- tuning: live encoder / scanner ---------------------------------
Global $CELL = 10                          ; live encoder cell px: 10 = 960x540 window
Global $HOLD_MS = 200                      ; min time per frame; rule: >= 2x scanner period (see tooltip)
Global $SHUFFLE = False                    ; True = random frame order per pass (no listening while receiving)
Global $JITTER_PCT = 40                    ; random extra hold 0..x% per frame, breaks scanner/encoder phase lock
Global $SAMPLES = 1                        ; scanner samples per cell: 1 = center only (fast), 5 = robust
Global $g_iCell = 10                       ; scanner cell size in px
Global $g_hGUI, $g_aBorder[4]
Global $g_oDict, $g_iTotal = 0, $g_iMaxCnt = -1

; ---- tuning: PNG export (for video) ---------------------------------
Global $EXPORT_CELL = 20                   ; 20 = 1920x1080 frames
Global $EXPORT_VFPS = 30                   ; video frame rate
Global $EXPORT_REPEAT = 3                  ; video frames per data frame (30/3 = 10 data frames/s)
Global $EXPORT_PASSES = 2                  ; how many times the whole file is repeated in the video

Local $sMode = ""
If $CmdLine[0] > 0 Then $sMode = $CmdLine[1]
If $sMode = "" Then
	Local $iAns = MsgBox(3 + 32, "BrAiNVC", "Yes = Live encoder" & @CRLF & "No = Scanner" & @CRLF & "Cancel = Export PNG frames (video)")
	Switch $iAns
		Case 6
			$sMode = "enc"
		Case 7
			$sMode = "scan"
		Case Else
			$sMode = "export"
	EndSwitch
EndIf
Switch $sMode
	Case "enc"
		_Encoder()
	Case "export"
		_Export()
	Case Else
		_Scanner()
EndSwitch

; =====================================================================
; shared
; =====================================================================
Func _Crc16Byte($iCrc, $iByte)
	$iCrc = BitXOR($iCrc, BitShift($iByte, -8))
	For $k = 0 To 7
		If BitAND($iCrc, 0x8000) Then
			$iCrc = BitAND(BitXOR(BitShift($iCrc, -1), 0x1021), 0xFFFF)
		Else
			$iCrc = BitAND(BitShift($iCrc, -1), 0xFFFF)
		EndIf
	Next
	Return $iCrc
EndFunc   ;==>_Crc16Byte

Func _FrameCrc(ByRef $aF)
	Local $iCrc = 0xFFFF
	For $i = 0 To 4
		$iCrc = _Crc16Byte($iCrc, $aF[$i])
	Next
	For $i = $HDR To $NBYTES - 1
		$iCrc = _Crc16Byte($iCrc, $aF[$i])
	Next
	Return $iCrc
EndFunc   ;==>_FrameCrc

Func _ReadFile($sFile)
	Local $hFile = FileOpen($sFile, 16)
	Local $bData = FileRead($hFile)
	FileClose($hFile)
	Return $bData
EndFunc   ;==>_ReadFile

; build the byte array of frame $f (header + payload + crc)
Func _BuildFrame(ByRef $bData, $f, $iFrames, ByRef $aF)
	Local $i, $n, $chunk, $tBuf, $iCrc
	For $i = 0 To $NBYTES - 1
		$aF[$i] = 0
	Next
	$chunk = BinaryMid($bData, $f * $PAY + 1, $PAY)
	$n = BinaryLen($chunk)
	$tBuf = DllStructCreate("byte[" & $PAY & "]")
	If $n > 0 Then DllStructSetData($tBuf, 1, $chunk)
	$aF[0] = BitAND(BitShift($f, 8), 0xFF)
	$aF[1] = BitAND($f, 0xFF)
	$aF[2] = BitAND(BitShift($n, 8), 0xFF)
	$aF[3] = BitAND($n, 0xFF)
	$aF[4] = ($f = $iFrames - 1) ? 1 : 0
	For $i = 0 To $PAY - 1
		$aF[$HDR + $i] = DllStructGetData($tBuf, 1, $i + 1)
	Next
	$iCrc = _FrameCrc($aF)
	$aF[5] = BitShift($iCrc, 8)
	$aF[6] = BitAND($iCrc, 0xFF)
EndFunc   ;==>_BuildFrame

; draw frame bytes into a GDI+ graphics context (black cell = 1), horizontal runs merged into one rect
Func _DrawFrame($hCtx, ByRef $aF, $iCell, $hBrush)
	Local $r, $cx, $i, $bit, $iRun
	_GDIPlus_GraphicsClear($hCtx, 0xFFFFFFFF)
	For $r = 0 To $ROWS - 1
		$iRun = -1
		For $cx = 0 To $COLS - 1
			$i = $r * $COLS + $cx
			$bit = BitAND(BitShift($aF[Int($i / 8)], 7 - Mod($i, 8)), 1)
			If $bit Then
				If $iRun < 0 Then $iRun = $cx
			ElseIf $iRun >= 0 Then
				_GDIPlus_GraphicsFillRect($hCtx, $iRun * $iCell, $r * $iCell, ($cx - $iRun) * $iCell, $iCell, $hBrush)
				$iRun = -1
			EndIf
		Next
		If $iRun >= 0 Then _GDIPlus_GraphicsFillRect($hCtx, $iRun * $iCell, $r * $iCell, ($COLS - $iRun) * $iCell, $iCell, $hBrush)
	Next
EndFunc   ;==>_DrawFrame

; =====================================================================
; live encoder
; =====================================================================
Func _Encoder()
	Local $sFile = FileOpenDialog("File to transmit", @ScriptDir, "All (*.*)")
	If @error Then Exit
	Local $bData = _ReadFile($sFile)
	Local $iFrames = Int((BinaryLen($bData) + $PAY - 1) / $PAY)
	If $iFrames < 1 Then $iFrames = 1

	_GDIPlus_Startup()
	Local $iW = $COLS * $CELL, $iH = $ROWS * $CELL
	Local $hGUI = GUICreate("BrAiNVC Encoder", $iW, $iH)
	GUISetBkColor(0xFFFFFF)
	GUISetState(@SW_SHOW)

	; off-screen GDI bitmap, copied to the window with ONE BitBlt (no visible top-to-bottom build-up)
	Local $hDC = _WinAPI_GetDC($hGUI)
	Local $hMemDC = _WinAPI_CreateCompatibleDC($hDC)
	Local $hBmp = _WinAPI_CreateCompatibleBitmap($hDC, $iW, $iH)
	_WinAPI_SelectObject($hMemDC, $hBmp)
	Local $hCtx = _GDIPlus_GraphicsCreateFromHDC($hMemDC)
	Local $hBlack = _GDIPlus_BrushCreateSolid(0xFF000000)

	Local $aOrder[$iFrames], $iPos = 0, $i
	For $i = 0 To $iFrames - 1
		$aOrder[$i] = $i
	Next

	Local $aF[$NBYTES], $f, $hT, $iPass = 0, $iHold
	While 1
		$hT = TimerInit()
		If $iPos = 0 Then
			If $SHUFFLE Then _Shuffle($aOrder)
			$iPass += 1
		EndIf
		$iHold = $HOLD_MS + Random(0, $HOLD_MS * $JITTER_PCT / 100, 1)
		$f = $aOrder[$iPos]

		_BuildFrame($bData, $f, $iFrames, $aF)
		_DrawFrame($hCtx, $aF, $CELL, $hBlack)
		_WinAPI_BitBlt($hDC, 0, 0, $iW, $iH, $hMemDC, 0, 0, 0x00CC0020)   ; SRCCOPY
		WinSetTitle($hGUI, "", "BrAiNVC Encoder  pass " & $iPass & ":  " & ($iPos + 1) & " / " & $iFrames & "   (frame id " & $f & ")")

		While TimerDiff($hT) < $iHold
			If GUIGetMsg() = $GUI_EVENT_CLOSE Then Exit
			Sleep(2)
		WEnd
		If GUIGetMsg() = $GUI_EVENT_CLOSE Then Exit
		$iPos = Mod($iPos + 1, $iFrames)
	WEnd
EndFunc   ;==>_Encoder

Func _Shuffle(ByRef $a)
	Local $j, $t
	For $i = UBound($a) - 1 To 1 Step -1
		$j = Random(0, $i, 1)
		$t = $a[$i]
		$a[$i] = $a[$j]
		$a[$j] = $t
	Next
EndFunc   ;==>_Shuffle

; =====================================================================
; PNG export (frames in order, passes repeated, ffmpeg batch file)
; =====================================================================
Func _Export()
	Local $sFile = FileOpenDialog("File to transmit", @ScriptDir, "All (*.*)")
	If @error Then Exit
	Local $sDir = FileSelectFolder("Output folder for PNG frames", @ScriptDir)
	If @error Then Exit
	Local $bData = _ReadFile($sFile)
	Local $iFrames = Int((BinaryLen($bData) + $PAY - 1) / $PAY)
	If $iFrames < 1 Then $iFrames = 1

	HotKeySet("{END}", "_Quit")
	_GDIPlus_Startup()
	Local $iW = $COLS * $EXPORT_CELL, $iH = $ROWS * $EXPORT_CELL
	Local $hBmp = _GDIPlus_BitmapCreateFromScan0($iW, $iH)
	Local $hCtx = _GDIPlus_ImageGetGraphicsContext($hBmp)
	Local $hBlack = _GDIPlus_BrushCreateSolid(0xFF000000)

	Local $aF[$NBYTES], $iNum = 0, $iOut = $iFrames * $EXPORT_PASSES, $iPass, $f
	For $iPass = 1 To $EXPORT_PASSES
		For $f = 0 To $iFrames - 1
			_BuildFrame($bData, $f, $iFrames, $aF)
			_DrawFrame($hCtx, $aF, $EXPORT_CELL, $hBlack)
			_GDIPlus_ImageSaveToFile($hBmp, $sDir & "\frame_" & StringFormat("%06d", $iNum) & ".png")
			$iNum += 1
			If Mod($iNum, 10) = 0 Then ToolTip("Exporting " & $iNum & " / " & $iOut & "   (End = abort)", 0, 0)
		Next
	Next
	ToolTip("")

	Local $sFF = @ScriptDir & "\ffmpeg.exe"
	Local $sBat = "@echo off" & @CRLF & "set FF=ffmpeg" & @CRLF & _
			"if exist """ & $sFF & """ set FF=""" & $sFF & """" & @CRLF & _
			"%FF% -y -framerate " & ($EXPORT_VFPS / $EXPORT_REPEAT) & " -i frame_%%06d.png -r " & $EXPORT_VFPS & _
			" -c:v libx264 -preset slow -crf 14 -pix_fmt yuv420p -g " & $EXPORT_VFPS & " brainvc.mp4" & @CRLF & "pause" & @CRLF
	Local $hBat = FileOpen($sDir & "\make_video.bat", 2)
	FileWrite($hBat, $sBat)
	FileClose($hBat)

	MsgBox(64, "BrAiNVC", "Exported " & $iOut & " frames (" & $iFrames & " x " & $EXPORT_PASSES & " passes) to" & @CRLF & $sDir & @CRLF & @CRLF & _
			"Run make_video.bat there (ffmpeg.exe next to this script, or in PATH) to build brainvc.mp4" & @CRLF & _
			"Video length: " & Round($iOut * $EXPORT_REPEAT / $EXPORT_VFPS / 60, 1) & " min")
EndFunc   ;==>_Export

; =====================================================================
; scanner
; =====================================================================
Func _Scanner()
	_GDIPlus_Startup()
	$g_hGUI = GUICreate("", 100, 100, 100, 100, $WS_POPUP, BitOR($WS_EX_LAYERED, $WS_EX_TOPMOST))
	GUISetBkColor(0x010203)
	For $i = 0 To 3
		$g_aBorder[$i] = GUICtrlCreateLabel("", 0, 0, 10, 10, -1, $GUI_WS_EX_PARENTDRAG)
		GUICtrlSetBkColor($g_aBorder[$i], 0xFF0000)
	Next
	GUISetState(@SW_SHOW)
	_WinAPI_SetLayeredWindowAttributes($g_hGUI, 0x010203, 255, 1)   ; color key = transparent hole
	_Relayout()
	HotKeySet("{PGUP}", "_Bigger")
	HotKeySet("{PGDN}", "_Smaller")
	HotKeySet("{END}", "_Quit")
	HotKeySet("{HOME}", "_SavePartial")

	Local $oDict = ObjCreate("Scripting.Dictionary")
	$g_oDict = $oDict
	Local $aB[$NBYTES], $aPos, $iTotal = 0, $i, $iCnt, $iLen, $sHex, $bAll, $hOut
	Local $iScan = 0, $iOk = 0, $hRate = TimerInit(), $sRate = ""
	While 1
		GUIGetMsg()
		$aPos = WinGetPos($g_hGUI)
		$iScan += 1
		If _Grab($aB, $aPos[0] + $BORDER, $aPos[1] + $BORDER) Then
			$iOk += 1
			$iCnt = $aB[0] * 256 + $aB[1]
			$iLen = $aB[2] * 256 + $aB[3]
			If Not $oDict.Exists($iCnt) Then
				$sHex = ""
				For $i = 0 To $iLen - 1
					$sHex &= Hex($aB[$HDR + $i], 2)
				Next
				$oDict.Item($iCnt) = $sHex
			EndIf
			$g_iMaxCnt = _Max($g_iMaxCnt, $iCnt)
			If BitAND($aB[4], 1) Then
				$iTotal = $iCnt + 1
				$g_iTotal = $iTotal
			EndIf
		EndIf
		If TimerDiff($hRate) >= 1000 Then
			$sRate = $iScan & " scans/s, " & $iOk & " ok/s"
			$iScan = 0
			$iOk = 0
			$hRate = TimerInit()
		EndIf
		ToolTip("frames " & $oDict.Count & "/" & ($iTotal > 0 ? $iTotal : "?") & "   cell " & $g_iCell & "px   " & $sRate & "   [Home = save partial]", $aPos[0], _Max($aPos[1] - 24, 0))

		If $iTotal > 0 And $oDict.Count >= $iTotal Then
			$bAll = True
			$sHex = ""
			For $i = 0 To $iTotal - 1
				If Not $oDict.Exists($i) Then
					$bAll = False
					ExitLoop
				EndIf
				$sHex &= $oDict.Item($i)
			Next
			If $bAll Then
				$hOut = FileOpen(@ScriptDir & "\received.bin", 2 + 16)
				If $sHex <> "" Then FileWrite($hOut, Binary("0x" & $sHex))
				FileClose($hOut)
				ToolTip("")
				MsgBox(64, "BrAiNVC", "Done. Saved received.bin (" & StringLen($sHex) / 2 & " bytes)")
				Exit
			EndIf
		EndIf
		Sleep(2)
	WEnd
EndFunc   ;==>_Scanner

; Home key: write what we have so far; missing frames are filled with zeros
; (keeps all later data at the right offset, so an MP3 just has short dropouts)
Func _SavePartial()
	If Not IsObj($g_oDict) Or $g_oDict.Count = 0 Then Return
	Local $iN = ($g_iTotal > 0) ? $g_iTotal : $g_iMaxCnt + 1
	Local $sZero = ""
	For $i = 1 To $PAY
		$sZero &= "00"
	Next
	Local $sHex = "", $iMissing = 0
	For $i = 0 To $iN - 1
		If $g_oDict.Exists($i) Then
			$sHex &= $g_oDict.Item($i)
		Else
			$sHex &= $sZero
			$iMissing += 1
		EndIf
	Next
	Local $sName = @ScriptDir & "\received_partial.bin"
	Local $hOut = FileOpen($sName, 2 + 16)
	If $sHex <> "" Then FileWrite($hOut, Binary("0x" & $sHex))
	FileClose($hOut)
	MsgBox(64, "BrAiNVC", "Saved " & $sName & @CRLF & ($iN - $iMissing) & " of " & $iN & " frames, " & $iMissing & " missing (zero-filled)" & _
			(($g_iTotal = 0) ? @CRLF & "Last frame not seen yet - file may be truncated." : ""))
EndFunc   ;==>_SavePartial

Func _Relayout()
	Local $w = $COLS * $g_iCell, $h = $ROWS * $g_iCell, $b = $BORDER
	Local $aPos = WinGetPos($g_hGUI)
	WinMove($g_hGUI, "", $aPos[0], $aPos[1], $w + 2 * $b, $h + 2 * $b)
	GUICtrlSetPos($g_aBorder[0], 0, 0, $w + 2 * $b, $b)
	GUICtrlSetPos($g_aBorder[1], 0, $h + $b, $w + 2 * $b, $b)
	GUICtrlSetPos($g_aBorder[2], 0, $b, $b, $h)
	GUICtrlSetPos($g_aBorder[3], $w + $b, $b, $b, $h)
EndFunc   ;==>_Relayout

Func _Bigger()
	$g_iCell = _Min($g_iCell + 1, 30)
	_Relayout()
EndFunc   ;==>_Bigger

Func _Smaller()
	$g_iCell = _Max($g_iCell - 1, 4)
	_Relayout()
EndFunc   ;==>_Smaller

Func _Quit()
	Exit
EndFunc   ;==>_Quit

; grab region, sample cells, rebuild bytes, verify CRC
Func _Grab(ByRef $aB, $x, $y)
	Local $w = $COLS * $g_iCell, $h = $ROWS * $g_iCell
	Local $hHBmp = _ScreenCapture_Capture("", $x, $y, $x + $w - 1, $y + $h - 1, False)
	If Not $hHBmp Then Return False
	Local $hImg = _GDIPlus_BitmapCreateFromHBITMAP($hHBmp)
	Local $w2 = _GDIPlus_ImageGetWidth($hImg), $h2 = _GDIPlus_ImageGetHeight($hImg)
	Local $bOk = False

	If $w2 >= $w - 2 And $h2 >= $h - 2 Then
		Local $tData = _GDIPlus_BitmapLockBits($hImg, 0, 0, $w2, $h2, $GDIP_ILMREAD, $GDIP_PXF32RGB)
		Local $iStride = DllStructGetData($tData, "Stride")
		Local $pScan = DllStructGetData($tData, "Scan0")
		Local $iPitch = Int(Abs($iStride) / 4)
		Local $pBase = $pScan
		If $iStride < 0 Then $pBase = Ptr($pScan + ($h2 - 1) * $iStride)
		Local $tPix = DllStructCreate("dword[" & $iPitch * $h2 & "]", $pBase)

		Local $c = $g_iCell, $iNS = $SAMPLES - 1
		Local $aOx[5] = [Int($c / 2), Int($c / 4), Int($c * 3 / 4), Int($c / 4), Int($c * 3 / 4)]
		Local $aOy[5] = [Int($c / 2), Int($c / 4), Int($c / 4), Int($c * 3 / 4), Int($c * 3 / 4)]
		Local $aLum[$NCELLS], $iMin = 999999, $iMax = -1
		Local $i, $k, $px, $py, $ry, $p, $s

		For $i = 0 To $NCELLS - 1
			$px = Mod($i, $COLS) * $c
			$py = Int($i / $COLS) * $c
			$s = 0
			For $k = 0 To $iNS
				$ry = $py + $aOy[$k]
				If $iStride < 0 Then $ry = $h2 - 1 - $ry
				$p = DllStructGetData($tPix, 1, $ry * $iPitch + $px + $aOx[$k] + 1)
				$s += BitAND(BitShift($p, 16), 0xFF) + BitAND(BitShift($p, 8), 0xFF) + BitAND($p, 0xFF)
			Next
			$aLum[$i] = $s
			$iMin = _Min($iMin, $s)
			$iMax = _Max($iMax, $s)
		Next

		If $iMax - $iMin > 400 * $SAMPLES Then   ; enough contrast to be a data frame
			Local $iThr = ($iMin + $iMax) / 2
			For $i = 0 To $NBYTES - 1
				$aB[$i] = 0
			Next
			For $i = 0 To $NCELLS - 1
				If $aLum[$i] < $iThr Then $aB[Int($i / 8)] = BitOR($aB[Int($i / 8)], BitShift(1, -(7 - Mod($i, 8))))
			Next
			Local $iCrc = _FrameCrc($aB)
			If $iCrc = $aB[5] * 256 + $aB[6] And $aB[2] * 256 + $aB[3] <= $PAY Then $bOk = True
		EndIf
		_GDIPlus_BitmapUnlockBits($hImg, $tData)
	EndIf

	_GDIPlus_BitmapDispose($hImg)
	_WinAPI_DeleteObject($hHBmp)
	Return $bOk
EndFunc   ;==>_Grab
