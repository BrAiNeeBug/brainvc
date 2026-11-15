; BrAiNVC - optical data channel, step 3 (128x72 grid + erasure coding across frames)
; Usage:  brainvc.au3 enc     = live encoder (shows frames in a window)
;         brainvc.au3 scan    = scanner (drag the red frame over the encoder window / video player)
;         brainvc.au3 export  = write frames.raw + make_video.bat (ffmpeg builds the video)
;         no argument         = chooser
; Scanner keys: PgUp/PgDn = resize frame +/-10px, numpad +/- = +/-1px, Home = save partial, End = quit
;
; Error correction: frames are sent in groups of FEC_K data frames + FEC_M parity frames
; (Reed-Solomon over GF(256), Cauchy matrix). ANY FEC_K frames out of a group of FEC_S
; are enough to rebuild the whole group, so up to FEC_M lost frames per group are fixed.
#include <GDIPlus.au3>
#include <ScreenCapture.au3>
#include <WinAPI.au3>
#include <GUIConstantsEx.au3>
#include <WindowsConstants.au3>
#include <Math.au3>

DllCall("user32.dll", "bool", "SetProcessDPIAware")

; ---- frame layout (16:9 grid, COLS*ROWS must be divisible by 8) -------
Global Const $COLS = 128, $ROWS = 72
Global Const $NCELLS = $COLS * $ROWS       ; 9216 cells = 9216 bits
Global Const $NBYTES = Int($NCELLS / 8)    ; 1152 bytes per frame
Global Const $HDR = 10                     ; n(2) N(2) fileLen(4) crc(2)
Global Const $PAY = $NBYTES - $HDR         ; 1142 payload bytes per frame
Global Const $BORDER = 6

; ---- error correction (encoder and scanner must use the same values) --
Global Const $FEC_K = 8                    ; data frames per group
Global Const $FEC_M = 2                    ; parity frames per group (25% overhead, fixes 2 lost frames per group)
Global Const $FEC_S = $FEC_K + $FEC_M

; ---- tuning: live encoder / scanner ---------------------------------
Global $CELL = 8                           ; live encoder cell px: 8 = 1024x576 window
Global $HOLD_MS = 150                      ; live encoder: time per frame; keep it above the scanner period (see tooltip)
Global $SHUFFLE = False                    ; True = random frame order per pass
Global $JITTER_PCT = 0                     ; live encoder: random extra hold 0..x% (only needed if the scanner is SLOWER than the frame rate)
Global $SAMPLES = 1                        ; scanner samples per cell: 1 = center only (fast), 5 = robust
Global $g_iW = 1024, $g_iH = 576               ; scanner frame size in px (any width, 16:9, resized with PgUp/PgDn and numpad +/-)
Global $g_hGUI, $g_aBorder[4]
Global $g_oDict, $g_iN = 0, $g_iLen = 0
Global $g_iThr = 0, $g_iFail = 0           ; sticky brightness threshold of the scanner

; ---- tuning: video export -------------------------------------------
Global $EXPORT_CELL = 15                   ; video upscale per cell: 15 = 1920x1080
Global $EXPORT_VFPS = 60                   ; video frame rate (60 = finer timing steps, YouTube gives 1080p60 more bitrate)
Global $EXPORT_DATA_FPS = 10              ; data frames per second; keep it clearly below the scanner's scans/s

Global $EXPORT_PASSES = 2                  ; how many times the whole file is repeated in the video

; ---- tables ---------------------------------------------------------
Global $g_aCrcTab[256]
Global $g_aExp[512], $g_aLog[256]
Global $g_aCoef[$FEC_M][$FEC_K]
Global $g_aMT[$FEC_M * $FEC_K][256]        ; multiplication tables for the Cauchy coefficients
Global $g_iGrpCache = -1, $g_aParity[$FEC_M][$PAY]

_InitCrc()
_InitFec()
Local $sMode = ""
If $CmdLine[0] > 0 Then $sMode = $CmdLine[1]
If $sMode = "" Then
	Local $iAns = MsgBox(3 + 32, "BrAiNVC", "Yes = Live encoder" & @CRLF & "No = Scanner" & @CRLF & "Cancel = Export video data (ffmpeg)")
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
; CRC16 (table driven)
; =====================================================================
Func _InitCrc()
	Local $c, $k
	For $i = 0 To 255
		$c = BitShift($i, -8)
		For $k = 0 To 7
			If BitAND($c, 0x8000) Then
				$c = BitAND(BitXOR(BitShift($c, -1), 0x1021), 0xFFFF)
			Else
				$c = BitAND(BitShift($c, -1), 0xFFFF)
			EndIf
		Next
		$g_aCrcTab[$i] = $c
	Next
EndFunc   ;==>_InitCrc

; CRC16-CCITT (init 0xFFFF) over header bytes 0-7 and payload
Func _FrameCrc(ByRef $aF)
	Local $iCrc = 0xFFFF, $i
	For $i = 0 To 7
		$iCrc = BitXOR(BitAND(BitShift($iCrc, -8), 0xFFFF), $g_aCrcTab[BitAND(BitXOR(BitShift($iCrc, 8), $aF[$i]), 0xFF)])
	Next
	For $i = $HDR To $NBYTES - 1
		$iCrc = BitXOR(BitAND(BitShift($iCrc, -8), 0xFFFF), $g_aCrcTab[BitAND(BitXOR(BitShift($iCrc, 8), $aF[$i]), 0xFF)])
	Next
	Return $iCrc
EndFunc   ;==>_FrameCrc

; =====================================================================
; GF(256) + Cauchy Reed-Solomon erasure code
; =====================================================================
Func _InitFec()
	Local $x = 1, $i, $j, $v, $c
	For $i = 0 To 254
		$g_aExp[$i] = $x
		$g_aLog[$x] = $i
		$x = BitShift($x, -1)
		If BitAND($x, 0x100) Then $x = BitXOR($x, 0x11D)
	Next
	For $i = 255 To 511
		$g_aExp[$i] = $g_aExp[$i - 255]
	Next
	For $j = 0 To $FEC_M - 1
		For $i = 0 To $FEC_K - 1
			$c = _GFInv(BitXOR($j, $FEC_M + $i))      ; Cauchy: 1 / (x_j xor y_i), x_j = j, y_i = M + i
			$g_aCoef[$j][$i] = $c
			For $v = 0 To 255
				$g_aMT[$j * $FEC_K + $i][$v] = _GFMul($c, $v)
			Next
		Next
	Next
EndFunc   ;==>_InitFec

Func _GFMul($a, $b)
	If $a = 0 Or $b = 0 Then Return 0
	Return $g_aExp[$g_aLog[$a] + $g_aLog[$b]]
EndFunc   ;==>_GFMul

Func _GFInv($a)
	Return $g_aExp[255 - $g_aLog[$a]]
EndFunc   ;==>_GFInv

; invert a d x d matrix over GF(256) (Gauss-Jordan); returns 2D array or 0
Func _GFInvMat(ByRef $aA, $d)
	Local $aMat[$d][2 * $d], $r, $c, $k, $p, $t, $f
	For $r = 0 To $d - 1
		For $c = 0 To $d - 1
			$aMat[$r][$c] = $aA[$r][$c]
			$aMat[$r][$d + $c] = ($r = $c) ? 1 : 0
		Next
	Next
	For $c = 0 To $d - 1
		$p = -1
		For $r = $c To $d - 1
			If $aMat[$r][$c] <> 0 Then
				$p = $r
				ExitLoop
			EndIf
		Next
		If $p < 0 Then Return 0
		If $p <> $c Then
			For $k = 0 To 2 * $d - 1
				$t = $aMat[$c][$k]
				$aMat[$c][$k] = $aMat[$p][$k]
				$aMat[$p][$k] = $t
			Next
		EndIf
		$f = _GFInv($aMat[$c][$c])
		For $k = 0 To 2 * $d - 1
			$aMat[$c][$k] = _GFMul($aMat[$c][$k], $f)
		Next
		For $r = 0 To $d - 1
			If $r <> $c And $aMat[$r][$c] <> 0 Then
				$f = $aMat[$r][$c]
				For $k = 0 To 2 * $d - 1
					$aMat[$r][$k] = BitXOR($aMat[$r][$k], _GFMul($f, $aMat[$c][$k]))
				Next
			EndIf
		Next
	Next
	Local $aInv[$d][$d]
	For $r = 0 To $d - 1
		For $c = 0 To $d - 1
			$aInv[$r][$c] = $aMat[$r][$d + $c]
		Next
	Next
	Return $aInv
EndFunc   ;==>_GFInvMat

; =====================================================================
; frame building (encoder side)
; =====================================================================
Func _ReadFile($sFile)
	Local $hFile = FileOpen($sFile, 16)
	Local $bData = FileRead($hFile)
	FileClose($hFile)
	Return $bData
EndFunc   ;==>_ReadFile

; total number of frames to transmit for a file (data + parity, full groups)
Func _FrameCount($iLen)
	Local $iD = Int(($iLen + $PAY - 1) / $PAY)
	If $iD < 1 Then $iD = 1
	Return Int(($iD + $FEC_K - 1) / $FEC_K) * $FEC_S
EndFunc   ;==>_FrameCount

Func _SizeOk($iN)
	If $iN > 65535 Then
		MsgBox(16, "BrAiNVC", "File too large: " & $iN & " frames (max 65535, about 50 MB).")
		Return False
	EndIf
	Return True
EndFunc   ;==>_SizeOk

; payload bytes of data frame $d (zero padded)
Func _DataBytes(ByRef $bData, $d, ByRef $aOut)
	Local $chunk = BinaryMid($bData, $d * $PAY + 1, $PAY)
	Local $tB = DllStructCreate("byte[" & $PAY & "]")
	If BinaryLen($chunk) > 0 Then DllStructSetData($tB, 1, $chunk)
	For $b = 0 To $PAY - 1
		$aOut[$b] = DllStructGetData($tB, 1, $b + 1)
	Next
EndFunc   ;==>_DataBytes

; compute the parity frames of group $g into $g_aParity
Func _CalcParity(ByRef $bData, $g)
	Local $aD[$PAY], $i, $j, $b, $iBase
	For $j = 0 To $FEC_M - 1
		For $b = 0 To $PAY - 1
			$g_aParity[$j][$b] = 0
		Next
	Next
	For $i = 0 To $FEC_K - 1
		_DataBytes($bData, $g * $FEC_K + $i, $aD)
		For $j = 0 To $FEC_M - 1
			$iBase = $j * $FEC_K + $i
			For $b = 0 To $PAY - 1
				$g_aParity[$j][$b] = BitXOR($g_aParity[$j][$b], $g_aMT[$iBase][$aD[$b]])
			Next
		Next
	Next
	$g_iGrpCache = $g
EndFunc   ;==>_CalcParity

; build the byte array of transmission frame $n (header + payload + crc)
Func _MakeFrame(ByRef $bData, $n, $iN, $iLen, ByRef $aF)
	Local $g = Int($n / $FEC_S), $t = Mod($n, $FEC_S), $i, $j, $iCrc
	Local $aP[$PAY]
	For $i = 0 To $NBYTES - 1
		$aF[$i] = 0
	Next
	If $t < $FEC_K Then
		_DataBytes($bData, $g * $FEC_K + $t, $aP)
		For $i = 0 To $PAY - 1
			$aF[$HDR + $i] = $aP[$i]
		Next
	Else
		If $g_iGrpCache <> $g Then _CalcParity($bData, $g)
		$j = $t - $FEC_K
		For $i = 0 To $PAY - 1
			$aF[$HDR + $i] = $g_aParity[$j][$i]
		Next
	EndIf
	$aF[0] = BitAND(BitShift($n, 8), 0xFF)
	$aF[1] = BitAND($n, 0xFF)
	$aF[2] = BitAND(BitShift($iN, 8), 0xFF)
	$aF[3] = BitAND($iN, 0xFF)
	$aF[4] = BitAND(BitShift($iLen, 24), 0xFF)
	$aF[5] = BitAND(BitShift($iLen, 16), 0xFF)
	$aF[6] = BitAND(BitShift($iLen, 8), 0xFF)
	$aF[7] = BitAND($iLen, 0xFF)
	$iCrc = _FrameCrc($aF)
	$aF[8] = BitShift($iCrc, 8)
	$aF[9] = BitAND($iCrc, 0xFF)
EndFunc   ;==>_MakeFrame

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
	Local $iLen = BinaryLen($bData)
	Local $iN = _FrameCount($iLen)
	If Not _SizeOk($iN) Then Exit

	_GDIPlus_Startup()
	Local $iW = $COLS * $CELL, $iH = $ROWS * $CELL
	Local $hGUI = GUICreate("BrAiNVC Encoder", $iW, $iH)
	GUISetBkColor(0xFFFFFF)
	GUISetState(@SW_SHOW)

	; off-screen GDI bitmap, copied to the window with ONE BitBlt
	Local $hDC = _WinAPI_GetDC($hGUI)
	Local $hMemDC = _WinAPI_CreateCompatibleDC($hDC)
	Local $hBmp = _WinAPI_CreateCompatibleBitmap($hDC, $iW, $iH)
	_WinAPI_SelectObject($hMemDC, $hBmp)
	Local $hCtx = _GDIPlus_GraphicsCreateFromHDC($hMemDC)
	Local $hBlack = _GDIPlus_BrushCreateSolid(0xFF000000)

	Local $aOrder[$iN], $iPos = 0, $i
	For $i = 0 To $iN - 1
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

		_MakeFrame($bData, $f, $iN, $iLen, $aF)
		_DrawFrame($hCtx, $aF, $CELL, $hBlack)
		_WinAPI_BitBlt($hDC, 0, 0, $iW, $iH, $hMemDC, 0, 0, 0x00CC0020)   ; SRCCOPY
		WinSetTitle($hGUI, "", "BrAiNVC Encoder  pass " & $iPass & ":  " & ($iPos + 1) & " / " & $iN & "   (frame " & $f & (Mod($f, $FEC_S) >= $FEC_K ? ", parity)" : ")"))

		While TimerDiff($hT) < $iHold
			If GUIGetMsg() = $GUI_EVENT_CLOSE Then Exit
			Sleep(2)
		WEnd
		If GUIGetMsg() = $GUI_EVENT_CLOSE Then Exit
		$iPos = Mod($iPos + 1, $iN)
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
; video export (raw 1-bit frames, each repeated a few video frames, ffmpeg batch file)
; =====================================================================
Func _Export()
	Local $sFile = FileOpenDialog("File to transmit", @ScriptDir, "All (*.*)")
	If @error Then Exit
	Local $sDir = FileSelectFolder("Output folder (frames.raw + make_video.bat)", @ScriptDir)
	If @error Then Exit
	; data frames per second: limited by the scanner (scans/s in its tooltip) and by the video (at least 2 video frames per data frame)
	Local $sRate = InputBox("BrAiNVC", "Data frames per second (video runs at " & $EXPORT_VFPS & " fps, max " & Int($EXPORT_VFPS / 2) & "):", $EXPORT_DATA_FPS, "", 360, 140)
	If Not @error And Number($sRate) > 0 Then $EXPORT_DATA_FPS = _Min(Number($sRate), $EXPORT_VFPS / 2)
	Local $bData = _ReadFile($sFile)
	Local $iLen = BinaryLen($bData)
	Local $iN = _FrameCount($iLen)
	If Not _SizeOk($iN) Then Exit

	; 1 bit per cell, MSB first, 128 cells = 16 bytes per row: exactly ffmpeg's "monow" rawvideo layout
	; every data frame is written 60/10 = 6 video frames long; a non-integer ratio alternates evenly (e.g. 7,8,7,8) so the rhythm stays smooth
	Local $hRaw = FileOpen($sDir & "\frames.raw", 2 + 16)
	Local $aF[$NBYTES], $tF = DllStructCreate("byte[" & $NBYTES & "]"), $bin
	Local $i, $k, $n, $iPass, $iRep, $iVid = 0, $iDone = 0, $iOut = $iN * $EXPORT_PASSES
	For $iPass = 1 To $EXPORT_PASSES
		For $n = 0 To $iN - 1
			_MakeFrame($bData, $n, $iN, $iLen, $aF)
			For $i = 0 To $NBYTES - 1
				DllStructSetData($tF, 1, $aF[$i], $i + 1)
			Next
			$bin = DllStructGetData($tF, 1)
			$iRep = _Max(Round(($iDone + 1) * $EXPORT_VFPS / $EXPORT_DATA_FPS) - Round($iDone * $EXPORT_VFPS / $EXPORT_DATA_FPS), 1)
			For $k = 1 To $iRep
				FileWrite($hRaw, $bin)
			Next
			$iVid += $iRep
			$iDone += 1
			If Mod($iDone, 20) = 0 Then ToolTip("Exporting " & $iDone & " / " & $iOut, 0, 0)
		Next
	Next
	FileClose($hRaw)
	ToolTip("")

	Local $sFF = @ScriptDir & "\ffmpeg.exe"
	Local $sBat = "@echo off" & @CRLF & "set FF=ffmpeg" & @CRLF & _
			"if exist """ & $sFF & """ set FF=""" & $sFF & """" & @CRLF & _
			"%FF% -y -f rawvideo -pix_fmt monow -video_size " & $COLS & "x" & $ROWS & " -framerate " & $EXPORT_VFPS & _
			" -i frames.raw -vf ""format=gray,scale=" & ($COLS * $EXPORT_CELL) & ":" & ($ROWS * $EXPORT_CELL) & ":flags=neighbor,format=yuv420p""" & _
			" -c:v libx264 -preset slow -crf 14 -g " & $EXPORT_VFPS & " brainvc.mp4" & @CRLF & "pause" & @CRLF
	Local $hBat = FileOpen($sDir & "\make_video.bat", 2)
	FileWrite($hBat, $sBat)
	FileClose($hBat)

	MsgBox(64, "BrAiNVC", "Exported " & $iOut & " frames (" & $iN & " x " & $EXPORT_PASSES & " passes, " & ($iN - Int($iN / $FEC_S) * $FEC_M) & " data + parity) to" & @CRLF & $sDir & @CRLF & @CRLF & _
			"Run make_video.bat there (ffmpeg.exe next to this script, or in PATH) to build brainvc.mp4" & @CRLF & _
			"Video length: " & Round($iVid / $EXPORT_VFPS / 60, 1) & " min")
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
	HotKeySet("{NUMPADADD}", "_BiggerFine")
	HotKeySet("{NUMPADSUB}", "_SmallerFine")
	HotKeySet("{END}", "_Quit")
	HotKeySet("{HOME}", "_SavePartial")

	$g_oDict = ObjCreate("Scripting.Dictionary")
	Local $aB[$NBYTES], $aPos, $i, $n, $iN, $sHex, $aRes
	Local $iScan = 0, $iOk = 0, $hRate = TimerInit(), $sRate = "", $hChk = TimerInit()
	While 1
		GUIGetMsg()
		$aPos = WinGetPos($g_hGUI)
		$iScan += 1
		If _Grab($aB, $aPos[0] + $BORDER, $aPos[1] + $BORDER) Then
			$n = $aB[0] * 256 + $aB[1]
			$iN = $aB[2] * 256 + $aB[3]
			If $iN > 0 And $n < $iN And Mod($iN, $FEC_S) = 0 Then
				$iOk += 1
				If Not $g_oDict.Exists($n) Then
					$sHex = ""
					For $i = 0 To $PAY - 1
						$sHex &= Hex($aB[$HDR + $i], 2)
					Next
					$g_oDict.Item($n) = $sHex
				EndIf
				$g_iN = $iN
				$g_iLen = $aB[4] * 16777216 + $aB[5] * 65536 + $aB[6] * 256 + $aB[7]
			EndIf
		EndIf
		If TimerDiff($hRate) >= 1000 Then
			$sRate = $iScan & " scans/s, " & $iOk & " ok/s"
			$iScan = 0
			$iOk = 0
			$hRate = TimerInit()
		EndIf
		ToolTip("frames " & $g_oDict.Count & "/" & ($g_iN > 0 ? $g_iN & "  (need " & Int($g_iN / $FEC_S) * $FEC_K & " in the right groups)" : "?") & "   " & $g_iW & "x" & $g_iH & "px (cell " & Round($g_iW / $COLS, 1) & ")   " & $sRate & "   [Home = save partial]", $aPos[0], _Max($aPos[1] - 24, 0))

		If $g_iN > 0 And TimerDiff($hChk) >= 1000 Then
			$hChk = TimerInit()
			If _AllGroupsOk() Then
				ToolTip("Recovering ...", $aPos[0], _Max($aPos[1] - 24, 0))
				$aRes = _Recover(False)
				ToolTip("")
				MsgBox(64, "BrAiNVC", "Done. Saved " & $aRes[0] & @CRLF & $g_iLen & " bytes, " & $aRes[1] & " frames rebuilt by error correction")
				Exit
			EndIf
		EndIf
		Sleep(2)
	WEnd
EndFunc   ;==>_Scanner

; true when every group has at least FEC_K of its FEC_S frames
Func _AllGroupsOk()
	Local $iG = Int($g_iN / $FEC_S), $g, $i, $c
	For $g = 0 To $iG - 1
		$c = 0
		For $i = 0 To $FEC_S - 1
			If $g_oDict.Exists($g * $FEC_S + $i) Then $c += 1
		Next
		If $c < $FEC_K Then Return False
	Next
	Return True
EndFunc   ;==>_AllGroupsOk

; hex string -> row $row of a 2D byte array
Func _HexToRow($sHex, ByRef $a, $row)
	Local $tB = DllStructCreate("byte[" & $PAY & "]")
	DllStructSetData($tB, 1, Binary("0x" & $sHex))
	For $b = 0 To $PAY - 1
		$a[$row][$b] = DllStructGetData($tB, 1, $b + 1)
	Next
EndFunc   ;==>_HexToRow

; rebuild the $d missing data frames of group starting at transmission index $n0
; returns array of hex strings (in the order of $aMiss) or 0
Func _RecoverGroup($n0, ByRef $aMiss, $d, ByRef $aParAv)
	Local $r, $c, $i, $j, $b, $v, $u, $s
	Local $aA[$d][$d]
	For $r = 0 To $d - 1
		For $c = 0 To $d - 1
			$aA[$r][$c] = $g_aCoef[$aParAv[$r]][$aMiss[$c]]
		Next
	Next
	Local $aInv = _GFInvMat($aA, $d)
	If Not IsArray($aInv) Then Return 0

	Local $aKnown[$FEC_K][$PAY], $aPb[$d][$PAY], $aIsKnown[$FEC_K]
	For $i = 0 To $FEC_K - 1
		$aIsKnown[$i] = $g_oDict.Exists($n0 + $i)
		If $aIsKnown[$i] Then _HexToRow($g_oDict.Item($n0 + $i), $aKnown, $i)
	Next
	For $r = 0 To $d - 1
		_HexToRow($g_oDict.Item($n0 + $FEC_K + $aParAv[$r]), $aPb, $r)
	Next

	Local $aRhs[$d], $aU[$d][$PAY]
	For $b = 0 To $PAY - 1
		For $r = 0 To $d - 1
			$v = $aPb[$r][$b]
			$j = $aParAv[$r]
			For $i = 0 To $FEC_K - 1
				If $aIsKnown[$i] Then $v = BitXOR($v, $g_aMT[$j * $FEC_K + $i][$aKnown[$i][$b]])
			Next
			$aRhs[$r] = $v
		Next
		For $c = 0 To $d - 1
			$u = 0
			For $r = 0 To $d - 1
				$u = BitXOR($u, _GFMul($aInv[$c][$r], $aRhs[$r]))
			Next
			$aU[$c][$b] = $u
		Next
	Next

	Local $aHex[$d]
	For $c = 0 To $d - 1
		$s = ""
		For $b = 0 To $PAY - 1
			$s &= Hex($aU[$c][$b], 2)
		Next
		$aHex[$c] = $s
	Next
	Return $aHex
EndFunc   ;==>_RecoverGroup

; assemble the file from what we have; fix lost data frames via parity where possible;
; frames that cannot be rebuilt are zero filled. Returns [file name, rebuilt frames, lost frames]
Func _Recover($bPartial)
	Local $iG = Int($g_iN / $FEC_S), $g, $i, $j, $m, $n0, $iMiss, $iPar, $aHex
	Local $aMiss[$FEC_K], $aParAv[$FEC_M]
	Local $sZero = "", $sOut = "", $iLost = 0, $iFixed = 0
	For $i = 1 To $PAY
		$sZero &= "00"
	Next
	For $g = 0 To $iG - 1
		$n0 = $g * $FEC_S
		$iMiss = 0
		For $i = 0 To $FEC_K - 1
			If Not $g_oDict.Exists($n0 + $i) Then
				$aMiss[$iMiss] = $i
				$iMiss += 1
			EndIf
		Next
		$aHex = 0
		If $iMiss > 0 Then
			$iPar = 0
			For $j = 0 To $FEC_M - 1
				If $g_oDict.Exists($n0 + $FEC_K + $j) Then
					$aParAv[$iPar] = $j
					$iPar += 1
				EndIf
			Next
			If $iMiss <= $iPar Then $aHex = _RecoverGroup($n0, $aMiss, $iMiss, $aParAv)
			If IsArray($aHex) Then
				$iFixed += $iMiss
			Else
				$iLost += $iMiss
			EndIf
		EndIf
		$m = 0
		For $i = 0 To $FEC_K - 1
			If $g_oDict.Exists($n0 + $i) Then
				$sOut &= $g_oDict.Item($n0 + $i)
			ElseIf IsArray($aHex) Then
				$sOut &= $aHex[$m]
				$m += 1
			Else
				$sOut &= $sZero
			EndIf
		Next
	Next
	$sOut = StringLeft($sOut, $g_iLen * 2)
	Local $sName = @ScriptDir & ($bPartial ? "\received_partial.bin" : "\received.bin")
	Local $hOut = FileOpen($sName, 2 + 16)
	If $sOut <> "" Then FileWrite($hOut, Binary("0x" & $sOut))
	FileClose($hOut)
	Local $aRes[3] = [$sName, $iFixed, $iLost]
	Return $aRes
EndFunc   ;==>_Recover

; Home key: write what we have so far (error correction applied, unrecoverable gaps zero filled)
Func _SavePartial()
	If Not IsObj($g_oDict) Or $g_oDict.Count = 0 Or $g_iN = 0 Then Return
	ToolTip("Recovering ...", 0, 0)
	Local $aRes = _Recover(True)
	ToolTip("")
	MsgBox(64, "BrAiNVC", "Saved " & $aRes[0] & @CRLF & $aRes[1] & " frames rebuilt by error correction, " & $aRes[2] & " data frames still missing (zero-filled)")
EndFunc   ;==>_SavePartial

Func _Relayout()
	$g_iH = Round($g_iW * $ROWS / $COLS)
	Local $w = $g_iW, $h = $g_iH, $b = $BORDER
	Local $aPos = WinGetPos($g_hGUI)
	WinMove($g_hGUI, "", $aPos[0], $aPos[1], $w + 2 * $b, $h + 2 * $b)
	GUICtrlSetPos($g_aBorder[0], 0, 0, $w + 2 * $b, $b)
	GUICtrlSetPos($g_aBorder[1], 0, $h + $b, $w + 2 * $b, $b)
	GUICtrlSetPos($g_aBorder[2], 0, $b, $b, $h)
	GUICtrlSetPos($g_aBorder[3], $w + $b, $b, $b, $h)
EndFunc   ;==>_Relayout

Func _Grow($iDelta)
	$g_iW = _Max(_Min($g_iW + $iDelta, 3000), 256)
	_Relayout()
EndFunc   ;==>_Grow

Func _Bigger()
	_Grow(10)
EndFunc   ;==>_Bigger

Func _Smaller()
	_Grow(-10)
EndFunc   ;==>_Smaller

Func _BiggerFine()
	_Grow(1)
EndFunc   ;==>_BiggerFine

Func _SmallerFine()
	_Grow(-1)
EndFunc   ;==>_SmallerFine

Func _Quit()
	Exit
EndFunc   ;==>_Quit

; grab region, sample cells (cell size may be fractional), rebuild bytes, verify CRC
; fast path: after one good frame the brightness threshold is reused, so each cell is read and
; packed into its byte in a single pass (only the green channel is used, frames are gray anyway)
Func _Grab(ByRef $aB, $x, $y)
	Local $w = $g_iW, $h = $g_iH
	Local $hHBmp = _ScreenCapture_Capture("", $x, $y, $x + $w - 1, $y + $h - 1, False)
	If Not $hHBmp Then Return False
	Local $hImg = _GDIPlus_BitmapCreateFromHBITMAP($hHBmp)
	Local $w2 = _GDIPlus_ImageGetWidth($hImg), $h2 = _GDIPlus_ImageGetHeight($hImg)
	Local $bOk = False

	If $w2 >= $w - 2 And $h2 >= $h - 2 Then
		Local $tData = _GDIPlus_BitmapLockBits($hImg, 0, 0, $w2, $h2, $GDIP_ILMREAD, $GDIP_PXF32RGB)
		Local $iStride = DllStructGetData($tData, "Stride")
		Local $pScan = DllStructGetData($tData, "Scan0")
		Local $iRow = Abs($iStride)                 ; bytes per row
		Local $pBase = $pScan
		If $iStride < 0 Then $pBase = Ptr($pScan + ($h2 - 1) * $iStride)
		Local $tPix = DllStructCreate("byte[" & $iRow * $h2 & "]", $pBase)   ; BGRA: byte 2 (1-based) = green

		; byte index of every sample: aXs = column part (x*4 + 2), aYs = row part (row * rowBytes)
		Local $cw = $w / $COLS, $ch = $h / $ROWS, $iNS = $SAMPLES - 1
		Local $aFx[5] = [0.5, 0.25, 0.75, 0.25, 0.75]
		Local $aFy[5] = [0.5, 0.25, 0.25, 0.75, 0.75]
		Local $aXs[$COLS][5], $aYs[$ROWS][5]
		Local $i, $k, $r, $cx, $bx, $q, $ry, $s, $cur
		For $k = 0 To 4
			For $cx = 0 To $COLS - 1
				$aXs[$cx][$k] = Int(($cx + $aFx[$k]) * $cw) * 4 + 2
			Next
			For $r = 0 To $ROWS - 1
				$ry = Int(($r + $aFy[$k]) * $ch)
				If $iStride < 0 Then $ry = $h2 - 1 - $ry
				$aYs[$r][$k] = $ry * $iRow
			Next
		Next

		Local $iBpr = Int($COLS / 8), $iMin = 999999, $iMax = -1, $iThr = $g_iThr
		If $iThr > 0 Then
			; ---- fast path: one pass, threshold from the last good frame
			For $r = 0 To $ROWS - 1
				For $bx = 0 To $iBpr - 1
					$cur = 0
					For $q = 0 To 7
						$cx = $bx * 8 + $q
						$s = 0
						For $k = 0 To $iNS
							$s += DllStructGetData($tPix, 1, $aYs[$r][$k] + $aXs[$cx][$k])
						Next
						If $s < $iMin Then $iMin = $s
						If $s > $iMax Then $iMax = $s
						$cur *= 2
						If $s < $iThr Then $cur += 1
					Next
					$aB[$r * $iBpr + $bx] = $cur
				Next
			Next
		Else
			; ---- slow path: measure min/max first, then pack
			Local $aLum[$NCELLS]
			For $r = 0 To $ROWS - 1
				For $cx = 0 To $COLS - 1
					$s = 0
					For $k = 0 To $iNS
						$s += DllStructGetData($tPix, 1, $aYs[$r][$k] + $aXs[$cx][$k])
					Next
					$aLum[$r * $COLS + $cx] = $s
					If $s < $iMin Then $iMin = $s
					If $s > $iMax Then $iMax = $s
				Next
			Next
			$iThr = ($iMin + $iMax) / 2
			For $i = 0 To $NBYTES - 1
				$cur = 0
				For $q = 0 To 7
					$cur *= 2
					If $aLum[$i * 8 + $q] < $iThr Then $cur += 1
				Next
				$aB[$i] = $cur
			Next
		EndIf

		If $iMax - $iMin > 100 * $SAMPLES Then   ; enough contrast to be a data frame
			If _FrameCrc($aB) = $aB[8] * 256 + $aB[9] Then
				$bOk = True
				$g_iThr = Int(($iMin + $iMax) / 2)
				$g_iFail = 0
			Else
				$g_iFail += 1
				If $g_iFail >= 3 Then   ; threshold probably stale (video brightness changed): measure again
					$g_iThr = 0
					$g_iFail = 0
				EndIf
			EndIf
		EndIf
		_GDIPlus_BitmapUnlockBits($hImg, $tData)
	EndIf

	_GDIPlus_BitmapDispose($hImg)
	_WinAPI_DeleteObject($hHBmp)
	Return $bOk
EndFunc   ;==>_Grab
