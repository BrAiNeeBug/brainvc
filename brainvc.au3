; BrAiNVC - optical data channel, step 4 (settings menu, settings are stored in brainvc.ini)
; Usage:  brainvc.au3                      = settings menu (start the modes from there)
;         brainvc.au3 enc | scan | export  = start a mode directly with the saved settings
;   enc     = live encoder (shows frames in a window)
;   scan    = scanner (drag the red frame over the encoder window / video player)
;   export  = write frames.raw + make_video.bat (ffmpeg builds the video)
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
#include <ComboConstants.au3>
#include <EditConstants.au3>
#include <Math.au3>

DllCall("user32.dll", "bool", "SetProcessDPIAware")

Global Const $INI = @ScriptDir & "\brainvc.ini"
Global Const $SEC = "brainvc"

; ---- frame layout (16:9 grid, COLS*ROWS must be divisible by 8) -------
Global $COLS = Int(_Cfg("Cols", 128)), $ROWS = Int(_Cfg("Rows", 72))
If $COLS < 16 Or $ROWS < 9 Or Mod($COLS * $ROWS, 8) <> 0 Then
	$COLS = 128
	$ROWS = 72
EndIf
Global $NCELLS = $COLS * $ROWS             ; e.g. 9216 cells = 9216 bits
Global $NBYTES = Int($NCELLS / 8)          ; e.g. 1152 bytes per frame
Global $HDR = 10                           ; n(2) N(2) fileLen(4) crc(2)
Global $PAY = $NBYTES - $HDR               ; payload bytes per frame
Global $BORDER = 6

; ---- error correction (encoder and scanner must use the same values) --
Global $FEC_K = Int(_Cfg("FecK", 8))       ; data frames per group
Global $FEC_M = Int(_Cfg("FecM", 2))       ; parity frames per group
If $FEC_K < 1 Or $FEC_M < 1 Or $FEC_K + $FEC_M > 255 Then
	$FEC_K = 8
	$FEC_M = 2
EndIf
Global $FEC_S = $FEC_K + $FEC_M

; ---- tuning: live encoder / scanner ---------------------------------
Global $CELL = Int(_Cfg("Cell", 8))                      ; live encoder cell px
Global $HOLD_MS = Int(_Cfg("HoldMs", 150))               ; live encoder: time per frame
Global $SHUFFLE = (Int(_Cfg("Shuffle", 0)) = 1)          ; True = random frame order per pass
Global $JITTER_PCT = Int(_Cfg("JitterPct", 0))           ; live encoder: random extra hold 0..x%
Global $SAMPLES = Int(_Cfg("Samples", 1))                ; scanner samples per cell: 1 (fast), 3, 5 (robust)
If $SAMPLES <> 1 And $SAMPLES <> 3 And $SAMPLES <> 5 Then $SAMPLES = 1
Global $g_iW = Int(_Cfg("ScanWidth", 1024)), $g_iH = Round($g_iW * $ROWS / $COLS)   ; scanner frame size in px
Global $g_hGUI, $g_aBorder[4]
Global $g_oDict, $g_iN = 0, $g_iLen = 0
Global $SCAN_MAX_FPS = Int(_Cfg("ScanMaxFps", 0))        ; scanner: limit scans per second (0 = as fast as possible)
Global $g_iNibThr = Int(_Cfg("Thr", 8))                  ; scanner: brightness threshold in 16ths (8 = middle)
If $g_iNibThr < 1 Or $g_iNibThr > 15 Then $g_iNibThr = 8
Global $g_hScrDC, $g_hMemDC, $g_hDib, $g_pBits, $g_tSmall, $g_tFrame
Global $g_aBin4[16], $g_aHex1[16], $g_sDark, $g_sBright

; ---- tuning: video export -------------------------------------------
Global $EXPORT_CELL = Int(1920 / $COLS)                  ; video upscale per cell (1920 px wide video)
Global $EXPORT_VFPS = Int(_Cfg("VideoFps", 60))          ; video frame rate
Global $EXPORT_DATA_FPS = Number(_Cfg("DataFps", 10))    ; data frames per second
Global $EXPORT_PASSES = Int(_Cfg("Passes", 2))           ; how many times the whole file is repeated in the video
If $EXPORT_DATA_FPS > $EXPORT_VFPS / 2 Then $EXPORT_DATA_FPS = $EXPORT_VFPS / 2

; ---- tables ---------------------------------------------------------
Global $g_aCrcTab[256]
Global $g_aExp[512], $g_aLog[256]
Global $g_aCoef[$FEC_M][$FEC_K]
Global $g_aMT[$FEC_M * $FEC_K][256]        ; multiplication tables for the Cauchy coefficients
Global $g_iGrpCache = -1, $g_aParity[$FEC_M][$PAY]

; ---- settings menu controls -----------------------------------------
Global $mGrid, $mK, $mM, $mCell, $mHold, $mJit, $mShuf, $mSamp, $mWidth, $mRate, $mThr, $mVfps, $mDfps, $mPass, $mInfo

Global $g_sMode = ""
If $CmdLine[0] > 0 Then $g_sMode = $CmdLine[1]
If $g_sMode = "" Then _Menu()
_InitCrc()
_InitFec()
Switch $g_sMode
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
	_InitScan()

	$g_oDict = ObjCreate("Scripting.Dictionary")
	Local $sFrame, $aPos, $n, $iN, $aRes
	Local $iScan = 0, $iOk = 0, $hRate = TimerInit(), $sRate = "", $hChk = TimerInit(), $hTip = TimerInit(), $hLoop
	Local $iMinMs = ($SCAN_MAX_FPS > 0) ? Int(1000 / $SCAN_MAX_FPS) : 0
	While 1
		$hLoop = TimerInit()
		GUIGetMsg()
		$aPos = WinGetPos($g_hGUI)
		$iScan += 1
		If _GrabFast($sFrame, $aPos[0] + $BORDER, $aPos[1] + $BORDER) Then
			$n = Dec(StringMid($sFrame, 1, 4))
			$iN = Dec(StringMid($sFrame, 5, 4))
			$iOk += 1
			If Not $g_oDict.Exists($n) Then $g_oDict.Item($n) = StringMid($sFrame, $HDR * 2 + 1, $PAY * 2)
			$g_iN = $iN
			$g_iLen = Dec(StringMid($sFrame, 9, 8))
		EndIf
		If TimerDiff($hRate) >= 1000 Then
			$sRate = $iScan & " scans/s, " & $iOk & " ok/s"
			$iScan = 0
			$iOk = 0
			$hRate = TimerInit()
		EndIf
		If TimerDiff($hTip) >= 250 Then
			$hTip = TimerInit()
			ToolTip("frames " & $g_oDict.Count & "/" & ($g_iN > 0 ? $g_iN & "  (need " & Int($g_iN / $FEC_S) * $FEC_K & " in the right groups)" : "?") & "   " & $g_iW & "x" & $g_iH & "px (cell " & Round($g_iW / $COLS, 1) & ")   " & $sRate & "   [Home = save partial]", $aPos[0], _Max($aPos[1] - 24, 0))
		EndIf

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
		If $iMinMs > 0 Then
			While TimerDiff($hLoop) < $iMinMs
				Sleep(1)
			WEnd
		Else
			Sleep(1)
		EndIf
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

; one-time setup for the fast scanner: a COLS x ROWS 32-bit DIB that the screen region is shrunk into by GDI
Func _InitScan()
	Local $tBMI = DllStructCreate("struct;dword Size;long Width;long Height;ushort Planes;ushort BitCount;dword Compression;dword SizeImage;long XPels;long YPels;dword ClrUsed;dword ClrImportant;endstruct")
	DllStructSetData($tBMI, "Size", DllStructGetSize($tBMI))
	DllStructSetData($tBMI, "Width", $COLS)
	DllStructSetData($tBMI, "Height", -$ROWS)      ; negative = top-down rows
	DllStructSetData($tBMI, "Planes", 1)
	DllStructSetData($tBMI, "BitCount", 32)
	DllStructSetData($tBMI, "Compression", 0)
	$g_hScrDC = _WinAPI_GetDC(0)
	$g_hMemDC = _WinAPI_CreateCompatibleDC($g_hScrDC)
	Local $aR = DllCall("gdi32.dll", "handle", "CreateDIBSection", "handle", $g_hScrDC, "struct*", $tBMI, "uint", 0, "ptr*", 0, "handle", 0, "dword", 0)
	$g_hDib = $aR[0]
	$g_pBits = $aR[4]
	_WinAPI_SelectObject($g_hMemDC, $g_hDib)
	; 1 sample = nearest pixel (fastest), 3 / 5 = HALFTONE (averages the whole cell, more robust)
	DllCall("gdi32.dll", "int", "SetStretchBltMode", "handle", $g_hMemDC, "int", ($SAMPLES = 1) ? 3 : 4)
	DllCall("gdi32.dll", "bool", "SetBrushOrgEx", "handle", $g_hMemDC, "int", 0, "int", 0, "ptr", 0)
	$g_tSmall = DllStructCreate("byte[" & $COLS * $ROWS * 4 & "]", $g_pBits)
	$g_tFrame = DllStructCreate("byte[" & $NBYTES & "]")
	For $v = 0 To 15
		$g_aBin4[$v] = BitAND(BitShift($v, 3), 1) & BitAND(BitShift($v, 2), 1) & BitAND(BitShift($v, 1), 1) & BitAND($v, 1) & ","
		$g_aHex1[$v] = Hex($v, 1)
	Next
	Local $sSet = "0123456789ABCDEF"
	$g_sDark = "[" & StringLeft($sSet, $g_iNibThr) & "]"
	$g_sBright = "[" & StringMid($sSet, $g_iNibThr + 1) & "]"
EndFunc   ;==>_InitScan

; Read one frame from the screen. GDI shrinks the region to one pixel per cell (native), then the
; whole frame is turned into bytes with string operations instead of a loop over every cell.
; Returns the frame as hex string (header + payload) when the CRC is fine.
Func _GrabFast(ByRef $sFrame, $x, $y)
	Local $r = DllCall("gdi32.dll", "bool", "StretchBlt", "handle", $g_hMemDC, "int", 0, "int", 0, "int", $COLS, "int", $ROWS, _
			"handle", $g_hScrDC, "int", $x, "int", $y, "int", $g_iW, "int", $g_iH, "dword", 0x00CC0020)
	If @error Or Not $r[0] Then Return False
	DllCall("gdi32.dll", "bool", "GdiFlush")

	Local $s = Hex(DllStructGetData($g_tSmall, 1))                ; BBGGRRAA per pixel, 8 hex chars
	$s = StringRegExpReplace($s, "..(.).{5}", "\1")               ; keep the high nibble of green -> 1 char per cell
	$s = StringRegExpReplace($s, $g_sDark, "1")                   ; dark cell = bit 1
	$s = StringRegExpReplace($s, $g_sBright, "0")
	$s = StringRegExpReplace($s, "(....)", "\1,")                 ; 4 bits per token
	For $v = 0 To 15
		$s = StringReplace($s, $g_aBin4[$v], $g_aHex1[$v])        ; token -> one hex digit
	Next
	If StringLen($s) <> $NBYTES * 2 Then Return False

	; cheap header check first, so torn / empty frames do not cost a CRC run
	Local $n = Dec(StringMid($s, 1, 4)), $iN = Dec(StringMid($s, 5, 4))
	If $iN = 0 Or $n >= $iN Or Mod($iN, $FEC_S) <> 0 Then Return False

	DllStructSetData($g_tFrame, 1, Binary("0x" & $s))
	Local $iCrc = 0xFFFF, $i
	For $i = 1 To 8
		$iCrc = BitXOR(BitAND(BitShift($iCrc, -8), 0xFFFF), $g_aCrcTab[BitAND(BitXOR(BitShift($iCrc, 8), DllStructGetData($g_tFrame, 1, $i)), 0xFF)])
	Next
	For $i = $HDR + 1 To $NBYTES
		$iCrc = BitXOR(BitAND(BitShift($iCrc, -8), 0xFFFF), $g_aCrcTab[BitAND(BitXOR(BitShift($iCrc, 8), DllStructGetData($g_tFrame, 1, $i)), 0xFF)])
	Next
	If $iCrc <> DllStructGetData($g_tFrame, 1, 9) * 256 + DllStructGetData($g_tFrame, 1, 10) Then Return False
	$sFrame = $s
	Return True
EndFunc   ;==>_GrabFast

; =====================================================================
; settings menu (writes brainvc.ini, then starts the chosen mode in a fresh process)
; =====================================================================

Func _Cfg($sKey, $vDef)
	Return IniRead($INI, $SEC, $sKey, $vDef)
EndFunc   ;==>_Cfg

; read a number field and clamp it
Func _Num($id, $iMin, $iMax)
	Local $v = Int(GUICtrlRead($id))
	If $v < $iMin Then $v = $iMin
	If $v > $iMax Then $v = $iMax
	Return $v
EndFunc   ;==>_Num

Func _SetCombo($id, $sList, $sSel)
	GUICtrlSetData($id, "")
	GUICtrlSetData($id, $sList, $sSel)
EndFunc   ;==>_SetCombo

Func _Menu()
	GUICreate("BrAiNVC - settings", 450, 640)
	GUISetFont(9, 400, 0, "Segoe UI")
	Local $y

	$y = 10
	GUICtrlCreateGroup("Frame format - encoder and scanner must match", 10, $y, 430, 112)
	GUICtrlCreateLabel("Grid (cells)", 25, $y + 26, 160, 18)
	$mGrid = GUICtrlCreateCombo("", 190, $y + 22, 110, 22, $CBS_DROPDOWNLIST)
	_SetCombo($mGrid, "96x54|128x72|160x90|192x108", $COLS & "x" & $ROWS)
	GUICtrlSetTip($mGrid, "More cells = more data per frame, but smaller cells are harder to read after video compression.")
	GUICtrlCreateLabel("Data frames per group (K)", 25, $y + 52, 160, 18)
	$mK = GUICtrlCreateInput($FEC_K, 190, $y + 48, 60, 22, $ES_NUMBER)
	GUICtrlSetTip($mK, "Larger K = less overhead, but a longer wait until a group can be rebuilt.")
	GUICtrlCreateLabel("Parity frames per group (M)", 25, $y + 78, 160, 18)
	$mM = GUICtrlCreateInput($FEC_M, 190, $y + 74, 60, 22, $ES_NUMBER)
	GUICtrlSetTip($mM, "Up to M lost frames per group of K+M are rebuilt. Overhead = M / (K+M).")
	GUICtrlCreateGroup("", -99, -99, 1, 1)

	$y = 132
	GUICtrlCreateGroup("Live encoder", 10, $y, 430, 128)
	GUICtrlCreateLabel("Cell size (px)", 25, $y + 26, 160, 18)
	$mCell = GUICtrlCreateInput($CELL, 190, $y + 22, 60, 22, $ES_NUMBER)
	GUICtrlSetTip($mCell, "Window size = grid x cell size (4-16)")
	GUICtrlCreateLabel("Hold per frame (ms)", 25, $y + 52, 160, 18)
	$mHold = GUICtrlCreateInput($HOLD_MS, 190, $y + 48, 60, 22, $ES_NUMBER)
	GUICtrlSetTip($mHold, "Keep this above the scanner's scan period (1000 / scans per second).")
	GUICtrlCreateLabel("Random extra hold (%)", 25, $y + 78, 160, 18)
	$mJit = GUICtrlCreateInput($JITTER_PCT, 190, $y + 74, 60, 22, $ES_NUMBER)
	GUICtrlSetTip($mJit, "Only needed if the scanner is slower than the frame rate (breaks the rhythm lock).")
	$mShuf = GUICtrlCreateCheckbox("Shuffle frame order each pass", 25, $y + 100, 260, 20)
	If $SHUFFLE Then GUICtrlSetState($mShuf, $GUI_CHECKED)
	GUICtrlCreateGroup("", -99, -99, 1, 1)

	$y = 270
	GUICtrlCreateGroup("Scanner", 10, $y, 430, 132)
	GUICtrlCreateLabel("Samples per cell", 25, $y + 26, 160, 18)
	$mSamp = GUICtrlCreateCombo("", 190, $y + 22, 60, 22, $CBS_DROPDOWNLIST)
	_SetCombo($mSamp, "1|3|5", $SAMPLES)
	GUICtrlSetTip($mSamp, "1 = nearest pixel per cell (fastest). 3 or 5 = average over the whole cell, more robust for blurry / compressed video.")
	GUICtrlCreateLabel("Start width (px)", 25, $y + 52, 160, 18)
	$mWidth = GUICtrlCreateInput($g_iW, 190, $y + 48, 60, 22, $ES_NUMBER)
	GUICtrlSetTip($mWidth, "Width of the red frame at start (256-3000). Resize it later with PgUp/PgDn and numpad +/-.")
	GUICtrlCreateLabel("Max scans per second", 25, $y + 78, 160, 18)
	$mRate = GUICtrlCreateInput($SCAN_MAX_FPS, 190, $y + 74, 60, 22, $ES_NUMBER)
	GUICtrlSetTip($mRate, "0 = as fast as possible. A limit lowers CPU load.")
	GUICtrlCreateLabel("Brightness threshold (1-15)", 25, $y + 104, 160, 18)
	$mThr = GUICtrlCreateInput($g_iNibThr, 190, $y + 100, 60, 22, $ES_NUMBER)
	GUICtrlSetTip($mThr, "Cells darker than this (in 16ths of full brightness) count as black. 8 = middle. Change it if the picture is very dark or washed out.")
	GUICtrlCreateGroup("", -99, -99, 1, 1)

	$y = 412
	GUICtrlCreateGroup("Video export", 10, $y, 430, 108)
	GUICtrlCreateLabel("Video frame rate (fps)", 25, $y + 26, 160, 18)
	$mVfps = GUICtrlCreateCombo("", 190, $y + 22, 60, 22, $CBS_DROPDOWNLIST)
	_SetCombo($mVfps, "30|60", $EXPORT_VFPS)
	$mDfps = GUICtrlCreateInput($EXPORT_DATA_FPS, 190, $y + 48, 60, 22, $ES_NUMBER)
	GUICtrlCreateLabel("Data frames per second", 25, $y + 52, 160, 18)
	GUICtrlSetTip($mDfps, "Keep it clearly below the scanner's scans/s. Max = video fps / 2.")
	GUICtrlCreateLabel("Repeats of the whole file", 25, $y + 78, 160, 18)
	$mPass = GUICtrlCreateInput($EXPORT_PASSES, 190, $y + 74, 60, 22, $ES_NUMBER)
	GUICtrlSetTip($mPass, "More repeats = lost frames get another chance (1-5).")
	GUICtrlCreateGroup("", -99, -99, 1, 1)

	$mInfo = GUICtrlCreateLabel("", 15, 528, 420, 62)

	Local $bEnc = GUICtrlCreateButton("Live encoder", 10, 598, 100, 32)
	Local $bScan = GUICtrlCreateButton("Scanner", 115, 598, 100, 32)
	Local $bExp = GUICtrlCreateButton("Export video", 220, 598, 100, 32)
	Local $bDef = GUICtrlCreateButton("Defaults", 325, 598, 115, 32)
	GUISetState(@SW_SHOW)

	Local $iMsg, $hT = TimerInit()
	_MenuInfo()
	While 1
		$iMsg = GUIGetMsg()
		Switch $iMsg
			Case $GUI_EVENT_CLOSE
				Exit
			Case $bEnc
				_MenuStart("enc")
			Case $bScan
				_MenuStart("scan")
			Case $bExp
				_MenuStart("export")
			Case $bDef
				_MenuDefaults()
		EndSwitch
		If TimerDiff($hT) > 250 Then
			_MenuInfo()
			$hT = TimerInit()
		EndIf
	WEnd
EndFunc   ;==>_Menu

; live estimate under the fields
Func _MenuInfo()
	Local $aG = StringSplit(GUICtrlRead($mGrid), "x", 2)
	If UBound($aG) < 2 Then Return
	Local $c = Int($aG[0]), $r = Int($aG[1])
	Local $iPay = Int($c * $r / 8) - 10
	Local $k = _Num($mK, 1, 64), $m = _Num($mM, 1, 8), $iCell = _Num($mCell, 4, 16)
	Local $iV = Int(GUICtrlRead($mVfps)), $fD = _Num($mDfps, 1, Int($iV / 2))
	Local $iEx = Int(1920 / $c)
	GUICtrlSetData($mInfo, "Frame: " & Int($c * $r / 8) & " bytes (" & $iPay & " payload), error correction overhead " & Round($m / ($k + $m) * 100) & " %" & @CRLF & _
			"Throughput at " & $fD & " data frames/s: about " & Round($fD * $iPay * $k / ($k + $m) / 1024, 1) & " kB/s" & @CRLF & _
			"Export video: " & $c * $iEx & "x" & $r * $iEx & " (cell " & $iEx & " px)   Live window: " & $c * $iCell & "x" & $r * $iCell & " px")
EndFunc   ;==>_MenuInfo

Func _MenuSave()
	Local $aG = StringSplit(GUICtrlRead($mGrid), "x", 2)
	If UBound($aG) = 2 Then
		IniWrite($INI, $SEC, "Cols", $aG[0])
		IniWrite($INI, $SEC, "Rows", $aG[1])
	EndIf
	IniWrite($INI, $SEC, "FecK", _Num($mK, 1, 64))
	IniWrite($INI, $SEC, "FecM", _Num($mM, 1, 8))
	IniWrite($INI, $SEC, "Cell", _Num($mCell, 4, 16))
	IniWrite($INI, $SEC, "HoldMs", _Num($mHold, 30, 2000))
	IniWrite($INI, $SEC, "JitterPct", _Num($mJit, 0, 100))
	IniWrite($INI, $SEC, "Shuffle", (GUICtrlRead($mShuf) = $GUI_CHECKED) ? 1 : 0)
	IniWrite($INI, $SEC, "Samples", Int(GUICtrlRead($mSamp)))
	IniWrite($INI, $SEC, "ScanWidth", _Num($mWidth, 256, 3000))
	IniWrite($INI, $SEC, "ScanMaxFps", _Num($mRate, 0, 500))
	IniWrite($INI, $SEC, "Thr", _Num($mThr, 1, 15))
	Local $iV = Int(GUICtrlRead($mVfps))
	IniWrite($INI, $SEC, "VideoFps", $iV)
	IniWrite($INI, $SEC, "DataFps", _Num($mDfps, 1, Int($iV / 2)))
	IniWrite($INI, $SEC, "Passes", _Num($mPass, 1, 5))
EndFunc   ;==>_MenuSave

; save, start the mode as a new process (so every setting, also grid / FEC, takes effect), close the menu
Func _MenuStart($sMode)
	_MenuSave()
	Local $sCmd = @Compiled ? '"' & @ScriptFullPath & '"' : '"' & @AutoItExe & '" "' & @ScriptFullPath & '"'
	Run($sCmd & " " & $sMode, @ScriptDir)
	Exit
EndFunc   ;==>_MenuStart

Func _MenuDefaults()
	_SetCombo($mGrid, "96x54|128x72|160x90|192x108", "128x72")
	GUICtrlSetData($mK, 8)
	GUICtrlSetData($mM, 2)
	GUICtrlSetData($mCell, 8)
	GUICtrlSetData($mHold, 150)
	GUICtrlSetData($mJit, 0)
	GUICtrlSetState($mShuf, $GUI_UNCHECKED)
	_SetCombo($mSamp, "1|3|5", "1")
	GUICtrlSetData($mWidth, 1024)
	GUICtrlSetData($mRate, 0)
	GUICtrlSetData($mThr, 8)
	_SetCombo($mVfps, "30|60", "60")
	GUICtrlSetData($mDfps, 10)
	GUICtrlSetData($mPass, 2)
EndFunc   ;==>_MenuDefaults
