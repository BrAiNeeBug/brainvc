; BrAiNVC - optical data link, file tool
;   ENCODE: any file -> video (frames with header, CRC16 and Reed-Solomon parity, optional beacon, built with ffmpeg)
;   DECODE: video -> the original file (ffmpeg shrinks every video frame to one pixel per cell, then the frames are read)
; The live scanner lives in the web version (brainvc.html); this script only works with files.
;
; Usage:  brainvc.au3              = menu
;         brainvc.au3 enc | dec    = start the encoder / decoder directly with the saved settings (brainvc.ini)
; Needs ffmpeg.exe next to this script (or in PATH) to build and to read videos.
#NoTrayIcon
#include <AutoItConstants.au3>
#include <GUIConstantsEx.au3>
#include <WindowsConstants.au3>
#include <StaticConstants.au3>
#include <ComboConstants.au3>
#include <EditConstants.au3>
#include <Math.au3>

Global Const $INI = @ScriptDir & "\brainvc.ini"
Global Const $APP_URL = "https://github.com/BrAiNeeBug/brainvc"
Global Const $APP_WEB = "https://braineebug.github.io/brainvc/brainvc.html"
Global Const $SEC = "brainvc"

; ---- frame layout (16:9 grid, COLS*ROWS must be divisible by 8) -------
Global $COLS = Int(_Cfg("Cols", 160)), $ROWS = Int(_Cfg("Rows", 90))
If $COLS < 16 Or $ROWS < 9 Or Mod($COLS * $ROWS, 8) <> 0 Then
	$COLS = 160
	$ROWS = 90
EndIf
Global $NCELLS = $COLS * $ROWS             ; e.g. 9216 cells = 9216 bits
Global $NBYTES = Int($NCELLS / 8)          ; e.g. 1152 bytes per frame
Global $HDR = 10                           ; n(2) N(2) fileLen(4) crc(2)
Global $PAY = $NBYTES - $HDR               ; payload bytes per frame

; ---- error correction (encoder and decoder must use the same values) --
Global $FEC_K = Int(_Cfg("FecK", 8))       ; data frames per group
Global $FEC_M = Int(_Cfg("FecM", 2))       ; parity frames per group
If $FEC_K < 1 Or $FEC_M < 1 Or $FEC_K + $FEC_M > 255 Then
	$FEC_K = 8
	$FEC_M = 2
EndIf
Global $FEC_S = $FEC_K + $FEC_M

; ---- encode settings ---------------------------------------------------
Global $EXPORT_CELL = Int(1920 / $COLS)                  ; video upscale per cell (1920 px wide video)
Global $EXPORT_VFPS = Int(_Cfg("VideoFps", 60))          ; video frame rate
Global $EXPORT_DATA_FPS = Number(_Cfg("DataFps", 10))    ; data frames per second
Global $EXPORT_PASSES = Int(_Cfg("Passes", 2))           ; how many times the whole file is repeated in the video
Global $BEACON_SEC = Int(_Cfg("BeaconSec", 5))           ; logo + 3-2-1 before the data, 0 = off
If $BEACON_SEC < 0 Or $BEACON_SEC > 30 Then $BEACON_SEC = 5
If $EXPORT_VFPS <> 30 And $EXPORT_VFPS <> 60 Then $EXPORT_VFPS = 60
If $EXPORT_DATA_FPS < 1 Then $EXPORT_DATA_FPS = 1
If $EXPORT_DATA_FPS > $EXPORT_VFPS / 2 Then $EXPORT_DATA_FPS = $EXPORT_VFPS / 2
If $EXPORT_PASSES < 1 Then $EXPORT_PASSES = 1
Global $RUN_FFMPEG = (Int(_Cfg("RunFfmpeg", 1)) = 1)     ; build the video right after writing the frames
Global $OPEN_FOLDER = (Int(_Cfg("OpenFolder", 1)) = 1)   ; open the output folder when done

; ---- decode settings ---------------------------------------------------
Global $g_iNibThr = Int(_Cfg("Thr", 8))                  ; brightness threshold in 16ths (8 = middle)
If $g_iNibThr < 1 Or $g_iNibThr > 15 Then $g_iNibThr = 8
Global $READ_FPS = Number(_Cfg("ReadFps", 0))            ; frames per second to read from the video, 0 = every frame
If $READ_FPS < 0 Then $READ_FPS = 0
Global $g_oDict, $g_iN = 0, $g_iLen = 0
Global $g_tFrame, $g_aBin4[16], $g_aHex1[16], $g_sDark, $g_sBright

; ---- tables --------------------------------------------------------------
Global $g_aCrcTab[256]
Global $g_aExp[512], $g_aLog[256]
Global $g_aCoef[$FEC_M][$FEC_K]
Global $g_aMT[$FEC_M * $FEC_K][256]        ; multiplication tables for the Cauchy coefficients
Global $g_iGrpCache = -1, $g_aParity[$FEC_M][$PAY]

; ---- menu colors / controls ----------------------------------------------
Global Const $C_BG = 0x0E1014, $C_FIELD = 0x1D222B, $C_LINE = 0x2A303B, $C_TXT = 0xE8EAEE, $C_DIM = 0x8B94A3
Global Const $C_ACC = 0x4CC2FF, $C_ACC_HOT = 0x7AD3FF, $C_BTN = 0x2A3140, $C_BTN_HOT = 0x3A4458, $C_OK = 0x4CD98A, $C_BAD = 0xFF6B6B, $C_WARN = 0xFFB454
Global $mGrid, $mK, $mM, $mVfps, $mDfps, $mPass, $mBeacon, $mRun, $mOpen, $mThr, $mRead, $mInfo
Global $g_aBtnId[8], $g_aBtnBase[8], $g_aBtnHot[8], $g_iBtnN = 0, $g_iHot = 0
Global $g_hPG = 0, $g_idPgTitle, $g_idPgStat, $g_idPgFill, $g_idPgCancel, $g_bPgCancel = False   ; progress window

Global $g_sMode = ""
If $CmdLine[0] > 0 Then $g_sMode = $CmdLine[1]
If $g_sMode = "" Then _Menu()
_InitCrc()
_InitFec()
Switch $g_sMode
	Case "enc"
		_Encode()
	Case "dec"
		_Decode()
EndSwitch
If $CmdLine[0] > 1 Then
	If $CmdLine[2] = "menu" Then _Relaunch("")       ; started from the menu: go back to it
EndIf
Exit

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

; =====================================================================
; beacon: logo and 3-2-1 countdown in a 5x7 pixel font inside a 1-cell border ring
; (same layout as the web version, which shows how well it is aligned while the beacon runs)
; =====================================================================
Func _Glyph($c)
	Switch $c
		Case "B"
			Return "11110" & "10001" & "10001" & "11110" & "10001" & "10001" & "11110"
		Case "r"
			Return "00000" & "00000" & "10110" & "11001" & "10000" & "10000" & "10000"
		Case "A"
			Return "01110" & "10001" & "10001" & "11111" & "10001" & "10001" & "10001"
		Case "i"
			Return "00100" & "00000" & "01100" & "00100" & "00100" & "00100" & "01110"
		Case "N"
			Return "10001" & "11001" & "10101" & "10011" & "10001" & "10001" & "10001"
		Case "V"
			Return "10001" & "10001" & "10001" & "10001" & "10001" & "01010" & "00100"
		Case "C"
			Return "01110" & "10001" & "10000" & "10000" & "10000" & "10001" & "01110"
		Case "3"
			Return "01110" & "10001" & "00001" & "00110" & "00001" & "10001" & "01110"
		Case "2"
			Return "01110" & "10001" & "00001" & "00010" & "00100" & "01000" & "11111"
		Case "1"
			Return "00100" & "01100" & "00100" & "00100" & "00100" & "00100" & "01110"
	EndSwitch
	Return "0000000000000000000000000000000000"
EndFunc   ;==>_Glyph

; fill $aF (frame bytes) with the beacon picture for $sText
Func _RenderBeacon($sText, ByRef $aF)
	Local $i, $r, $c, $k, $gx, $gy, $dx, $dy, $sG
	For $i = 0 To $NBYTES - 1
		$aF[$i] = 0
	Next
	For $r = 0 To $ROWS - 1
		For $c = 0 To $COLS - 1
			If $r = 0 Or $r = $ROWS - 1 Or $c = 0 Or $c = $COLS - 1 Then
				$i = $r * $COLS + $c
				$aF[Int($i / 8)] = BitOR($aF[Int($i / 8)], BitShift(0x80, Mod($i, 8)))
			EndIf
		Next
	Next
	Local $n = StringLen($sText), $iW = $n * 6 - 1
	Local $s = Int(_Min(($COLS - 4) / $iW, ($ROWS - 4) / 7))
	If $s < 1 Then $s = 1
	Local $x0 = Int(($COLS - $iW * $s) / 2), $y0 = Int(($ROWS - 7 * $s) / 2)
	For $k = 0 To $n - 1
		$sG = _Glyph(StringMid($sText, $k + 1, 1))
		For $gy = 0 To 6
			For $gx = 0 To 4
				If StringMid($sG, $gy * 5 + $gx + 1, 1) = "1" Then
					For $dy = 0 To $s - 1
						For $dx = 0 To $s - 1
							$i = ($y0 + $gy * $s + $dy) * $COLS + $x0 + ($k * 6 + $gx) * $s + $dx
							$aF[Int($i / 8)] = BitOR($aF[Int($i / 8)], BitShift(0x80, Mod($i, 8)))
						Next
					Next
				EndIf
			Next
		Next
	Next
EndFunc   ;==>_RenderBeacon

; write the beacon picture for $fSec seconds into frames.raw, returns the number of video frames
Func _WriteBeacon($hRaw, $sText, $fSec)
	Local $aF[$NBYTES], $tF = DllStructCreate("byte[" & $NBYTES & "]"), $i
	_RenderBeacon($sText, $aF)
	For $i = 0 To $NBYTES - 1
		DllStructSetData($tF, 1, $aF[$i], $i + 1)
	Next
	Local $bin = DllStructGetData($tF, 1), $iCount = Round($fSec * $EXPORT_VFPS)
	For $i = 1 To $iCount
		FileWrite($hRaw, $bin)
	Next
	Return $iCount
EndFunc   ;==>_WriteBeacon

; =====================================================================
; ENCODE: file -> frames.raw -> video
; =====================================================================
Func _Encode()
	Local $sFile = FileOpenDialog("File to encode", @ScriptDir, "All (*.*)")
	If @error Then Return
	Local $sBase = StringRegExpReplace($sFile, "^.*\\|\.[^.\\]*$", "")
	Local $sDir = FileSelectFolder("Output folder for the video", StringRegExpReplace($sFile, "\\[^\\]*$", ""))
	If @error Then Return
	Local $bData = _ReadFile($sFile)
	Local $iLen = BinaryLen($bData)
	Local $iN = _FrameCount($iLen)
	If Not _SizeOk($iN) Then Return
	Local $iOut = $iN * $EXPORT_PASSES
	Local $fSecs = $iOut / $EXPORT_DATA_FPS
	If $BEACON_SEC > 0 Then $fSecs += $BEACON_SEC + 3
	If MsgBox(1 + 64, "BrAiNVC", $iLen & " bytes  ->  " & $iN & " frames (" & Int($iN / $FEC_S) & " groups of " & $FEC_S & ")" & @CRLF & _
			$EXPORT_PASSES & " pass(es) at " & $EXPORT_DATA_FPS & " data frames/s: the video will be about " & _TimeStr($fSecs) & " long." & @CRLF & @CRLF & "Continue?") <> 1 Then Return

	; 1 bit per cell, MSB first: exactly ffmpeg's "monow" rawvideo layout. Every data frame lasts VFPS/DATA_FPS video frames;
	; a non-integer ratio alternates evenly (e.g. 7,8,7,8) so the rhythm stays smooth
	Local $hRaw = FileOpen($sDir & "\frames.raw", 2 + 16)
	Local $aF[$NBYTES], $tF = DllStructCreate("byte[" & $NBYTES & "]"), $bin
	Local $i, $k, $n, $iPass, $iRep, $iVid = 0, $iDone = 0, $hT0 = TimerInit()
	_PgOpen("Encoding")
	_PgSet(0, "Writing the beacon ...")
	If $BEACON_SEC > 0 Then   ; logo, then 3-2-1, before the first data frame
		$iVid += _WriteBeacon($hRaw, "BrAiNVC", $BEACON_SEC)
		For $k = 3 To 1 Step -1
			$iVid += _WriteBeacon($hRaw, String($k), 1)
		Next
	EndIf
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
			If Mod($iDone, 10) = 0 Then
				_PgSet($iDone * 100 / $iOut, "Writing frames   " & $iDone & " / " & $iOut & "   -   " & Int($iDone * 100 / $iOut) & " %" & @CRLF & _TimeStr(TimerDiff($hT0) / 1000) & " elapsed")
				If _PgPoll() Then
					FileClose($hRaw)
					_PgClose()
					MsgBox(48, "BrAiNVC", "Cancelled.")
					Return
				EndIf
			EndIf
		Next
	Next
	FileClose($hRaw)

	Local $sFF = _FindFfmpeg()
	Local $sVideo = $sDir & "\" & $sBase & ".mp4"
	Local $sVf = "format=gray,scale=" & ($COLS * $EXPORT_CELL) & ":" & ($ROWS * $EXPORT_CELL) & ":flags=neighbor,format=yuv420p"
	Local $sArgs = ' -y -f rawvideo -pix_fmt monow -video_size ' & $COLS & 'x' & $ROWS & ' -framerate ' & $EXPORT_VFPS & _
			' -i frames.raw -vf "' & $sVf & '" -c:v libx264 -preset slow -crf 14 -g ' & $EXPORT_VFPS & ' "' & $sVideo & '"'
	Local $hBat = FileOpen($sDir & "\make_video.bat", 2)
	FileWrite($hBat, "@echo off" & @CRLF & '"' & ($sFF = "" ? "ffmpeg" : $sFF) & '"' & $sArgs & @CRLF & "pause" & @CRLF)
	FileClose($hBat)

	Local $sMsg = $iOut & " frames written (" & _TimeStr($iVid / $EXPORT_VFPS) & " of video)." & @CRLF
	Local $bUseFF = ($RUN_FFMPEG And $sFF <> "")
	If $bUseFF Then
		; ffmpeg reports its progress through a pipe (frame=...), shown in the window
		_PgTitle("Building the video with ffmpeg")
		_PgSet(0, "Starting ffmpeg ...")
		Local $sArgsP = StringReplace($sArgs, " -y ", " -y -progress pipe:1 -nostats ", 1)
		Local $iPid = Run('"' & $sFF & '"' & $sArgsP, $sDir, @SW_HIDE, $STDOUT_CHILD)
		Local $sBuf = "", $sRd, $aM, $iFr = 0, $fPct, $fEl, $hUi = TimerInit(), $bCancel = False
		$hT0 = TimerInit()
		While ProcessExists($iPid)
			$sRd = StdoutRead($iPid)
			If $sRd <> "" Then
				$sBuf = StringRight($sBuf & $sRd, 800)
				$aM = StringRegExp($sBuf, "frame=\s*(\d+)", 3)
				If IsArray($aM) Then $iFr = Int($aM[UBound($aM) - 1])
			EndIf
			If TimerDiff($hUi) > 150 Then
				$hUi = TimerInit()
				$fPct = _Min(100, $iFr * 100 / $iVid)
				$fEl = TimerDiff($hT0) / 1000
				_PgSet($fPct, "Frame " & $iFr & " / " & $iVid & "   -   " & Int($fPct) & " %" & @CRLF & _TimeStr($fEl) & " elapsed" & ($fPct > 2 ? ",  about " & _TimeStr($fEl * (100 - $fPct) / $fPct) & " left" : ""))
			EndIf
			If _PgPoll() Then
				$bCancel = True
				ProcessClose($iPid)
				ExitLoop
			EndIf
			Sleep(50)
		WEnd
		_PgClose()
		If $bCancel Then
			Sleep(300)
			FileDelete($sVideo)
			MsgBox(48, "BrAiNVC", "Cancelled. The frames (frames.raw) and make_video.bat are still in the output folder.")
			Return
		EndIf
		If FileExists($sVideo) And FileGetSize($sVideo) > 0 Then
			$sMsg &= @CRLF & "Video: " & $sVideo & @CRLF & "(" & Round(FileGetSize($sVideo) / 1048576, 1) & " MB)"
		Else
			$sMsg &= @CRLF & "ffmpeg did not create the video. Run make_video.bat in the output folder to see the error."
		EndIf
	Else
		_PgClose()
		If $sFF = "" Then
			$sMsg &= @CRLF & "ffmpeg.exe was not found (next to this script or in PATH)." & @CRLF & "Put it there and run make_video.bat in the output folder."
		Else
			$sMsg &= @CRLF & "Run make_video.bat in the output folder to build the video."
		EndIf
	EndIf
	MsgBox(64, "BrAiNVC - encode finished", $sMsg)
	If $OPEN_FOLDER Then ShellExecute($sDir)
EndFunc   ;==>_Encode

Func _TimeStr($fSec)
	Local $s = Int($fSec)
	Return StringFormat("%d:%02d", Int($s / 60), Mod($s, 60))
EndFunc   ;==>_TimeStr

; full path of ffmpeg.exe next to the script, "ffmpeg" when it is in PATH, "" when it cannot be found
Func _FindFfmpeg()
	If FileExists(@ScriptDir & "\ffmpeg.exe") Then Return @ScriptDir & "\ffmpeg.exe"
	If RunWait(@ComSpec & ' /c where ffmpeg >nul 2>&1', @ScriptDir, @SW_HIDE) = 0 Then Return "ffmpeg"
	Return ""
EndFunc   ;==>_FindFfmpeg

; =====================================================================
; DECODE: video -> frames -> file
; =====================================================================
Func _Decode()
	Local $sVid = FileOpenDialog("Video to decode", @ScriptDir, "Video (*.mp4;*.mkv;*.webm;*.mov;*.avi;*.m4v)|All (*.*)")
	If @error Then Return
	Local $sFF = _FindFfmpeg()
	If $sFF = "" Then
		MsgBox(48, "BrAiNVC", "ffmpeg.exe was not found." & @CRLF & "Put it next to this script (or into PATH) - it is needed to read the video.")
		Return
	EndIf

	; 1) ffmpeg shrinks every video frame to COLS x ROWS gray pixels (box average = exactly one value per cell)
	_PgOpen("Extracting the frames with ffmpeg")
	_PgSet(0, "Reading the video ...")
	Local $fDur = _VideoDuration($sFF, $sVid)
	Local $sTmp = @TempDir & "\brainvc_frames.raw"
	FileDelete($sTmp)
	Local $sVf = ($READ_FPS > 0 ? "fps=" & $READ_FPS & "," : "") & "scale=" & $COLS & ":" & $ROWS & ":flags=area,format=gray"
	Local $sSync = ($READ_FPS > 0 ? "" : " -vsync 0")      ; keep every video frame exactly once (no duplicated or dropped frames)
	Local $iPid = Run('"' & $sFF & '" -y -v error -progress pipe:1 -nostats -i "' & $sVid & '" -an -sn' & $sSync & ' -vf "' & $sVf & '" -f rawvideo -pix_fmt gray "' & $sTmp & '"', @ScriptDir, @SW_HIDE, $STDOUT_CHILD)
	Local $sBuf = "", $sRd, $aM, $fSec = 0, $fPct, $fEl, $hUi = TimerInit(), $hT0 = TimerInit(), $bCancel = False, $iU = 0
	While ProcessExists($iPid)
		$sRd = StdoutRead($iPid)
		If $sRd <> "" Then
			$sBuf = StringRight($sBuf & $sRd, 800)
			$aM = StringRegExp($sBuf, "out_time=(\d+):(\d+):(\d+(?:\.\d+)?)", 3)
			If IsArray($aM) Then
				$iU = UBound($aM)
				$fSec = Int($aM[$iU - 3]) * 3600 + Int($aM[$iU - 2]) * 60 + Number($aM[$iU - 1])
			EndIf
		EndIf
		If TimerDiff($hUi) > 150 Then
			$hUi = TimerInit()
			$fEl = TimerDiff($hT0) / 1000
			If $fDur > 0 Then
				$fPct = _Min(100, $fSec * 100 / $fDur)
				_PgSet($fPct, "Video time " & _TimeStr($fSec) & " / " & _TimeStr($fDur) & "   -   " & Int($fPct) & " %" & @CRLF & _TimeStr($fEl) & " elapsed" & ($fPct > 2 ? ",  about " & _TimeStr($fEl * (100 - $fPct) / $fPct) & " left" : ""))
			Else
				_PgSet(0, "Extracted " & Round(FileGetSize($sTmp) / 1048576) & " MB" & @CRLF & _TimeStr($fEl) & " elapsed")
			EndIf
		EndIf
		If _PgPoll() Then
			$bCancel = True
			ProcessClose($iPid)
			ExitLoop
		EndIf
		Sleep(50)
	WEnd
	If $bCancel Then
		_PgClose()
		Sleep(300)
		FileDelete($sTmp)
		MsgBox(48, "BrAiNVC", "Cancelled.")
		Return
	EndIf
	Local $iFS = $COLS * $ROWS, $iFrames = Int(FileGetSize($sTmp) / $iFS)
	If $iFrames < 1 Then
		_PgClose()
		FileDelete($sTmp)
		MsgBox(48, "BrAiNVC", "ffmpeg could not read frames from this video.")
		Return
	EndIf

	; 2) read the frames: every new valid data frame is stored, repeats of a frame are skipped almost for free
	_PgTitle("Reading the frames")
	_InitDecode()
	$g_oDict = ObjCreate("Scripting.Dictionary")
	$g_iN = 0
	$g_iLen = 0
	Local $hRaw = FileOpen($sTmp, 16)
	Local $bin, $iRes, $iNew = 0, $iDup = 0, $iOther = 0, $iSeen = 0
	$hUi = TimerInit()
	$hT0 = TimerInit()
	While 1
		$bin = FileRead($hRaw, $iFS)
		If BinaryLen($bin) < $iFS Then ExitLoop
		$iSeen += 1
		$iRes = _GrayFrame($bin)
		Switch $iRes
			Case 1
				$iNew += 1
			Case 2
				$iDup += 1
			Case Else
				$iOther += 1
		EndSwitch
		If TimerDiff($hUi) > 200 Then
			$hUi = TimerInit()
			$fPct = $iSeen * 100 / $iFrames
			_PgSet($fPct, "Video frame " & $iSeen & " / " & $iFrames & "   -   " & Int($fPct) & " %" & @CRLF & "data frames found: " & $iNew & ($g_iN > 0 ? " of " & $g_iN : "") & "   -   " & _TimeStr(TimerDiff($hT0) / 1000) & " elapsed")
			If _PgPoll() Then
				FileClose($hRaw)
				FileDelete($sTmp)
				_PgClose()
				MsgBox(48, "BrAiNVC", "Cancelled.")
				Return
			EndIf
			If $g_iN > 0 And _AllGroupsOk() Then ExitLoop      ; everything needed is there
		EndIf
	WEnd
	FileClose($hRaw)
	FileDelete($sTmp)
	_PgClose()
	If $g_iN = 0 Then
		MsgBox(48, "BrAiNVC", "No data frames found in " & $iSeen & " video frames." & @CRLF & @CRLF & _
				"Check that grid, K and M match the encoder, and that this is a video made by BrAiNVC (not a screen recording of it).")
		Return
	EndIf

	; 3) rebuild lost frames with the parity frames and write the file
	Local $aRes = _Recover()
	Local $sOut = $aRes[0], $iFixed = $aRes[1], $iLost = $aRes[2]
	Local $sExt = _SniffExt(StringLeft($sOut, 160))
	Local $sFileOut = StringRegExpReplace($sVid, "\.[^.\\]*$", "") & ".decoded" & ($iLost > 0 ? ".partial" : "") & "." & $sExt
	Local $hOut = FileOpen($sFileOut, 2 + 16)
	If $sOut <> "" Then FileWrite($hOut, Binary("0x" & $sOut))
	FileClose($hOut)

	Local $sMsg = ($iLost = 0 ? "Complete." : "Incomplete: " & $iLost & " data frame(s) are missing (zero-filled).") & @CRLF & @CRLF & _
			$sFileOut & @CRLF & $g_iLen & " bytes (" & $sExt & ")" & @CRLF & @CRLF & _
			$iSeen & " video frames read, " & $iNew & " data frames found, " & $iDup & " repeats skipped, " & $iOther & " not usable" & @CRLF & _
			$iFixed & " frames rebuilt by error correction"
	MsgBox(($iLost = 0 ? 64 : 48), "BrAiNVC - decode finished", $sMsg)
	If $OPEN_FOLDER Then ShellExecute(StringRegExpReplace($sFileOut, "\\[^\\]*$", ""))
EndFunc   ;==>_Decode

; length of a video in seconds (asks ffmpeg, 0 when unknown)
Func _VideoDuration($sFF, $sVid)
	Local $iPid = Run('"' & $sFF & '" -hide_banner -i "' & $sVid & '"', @ScriptDir, @SW_HIDE, $STDERR_CHILD)
	Local $sErr = "", $s
	While 1
		$s = StderrRead($iPid)
		If @error Then ExitLoop
		$sErr &= $s
		Sleep(10)
	WEnd
	Local $a = StringRegExp($sErr, "Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)", 3)
	If Not IsArray($a) Then Return 0
	Return Int($a[0]) * 3600 + Int($a[1]) * 60 + Number($a[2])
EndFunc   ;==>_VideoDuration

; =====================================================================
; progress window (same look as the menu; Cancel button / closing the window = cancel)
; =====================================================================
Func _PgOpen($sTitle)
	$g_hPG = GUICreate("BrAiNVC", 480, 166, -1, -1, BitOR($WS_CAPTION, $WS_SYSMENU))
	GUISetBkColor($C_BG, $g_hPG)
	GUISetFont(9, 400, 0, "Segoe UI")
	$g_idPgTitle = _T($sTitle, 24, 14, 432, 26, $C_ACC)
	GUICtrlSetFont($g_idPgTitle, 13, 700, 0, "Segoe UI")
	$g_idPgStat = _T("", 24, 50, 432, 40, $C_DIM)
	Local $id = GUICtrlCreateLabel("", 24, 100, 432, 10)           ; bar track
	GUICtrlSetBkColor($id, $C_FIELD)
	$g_idPgFill = GUICtrlCreateLabel("", 24, 100, 1, 10)           ; bar fill
	GUICtrlSetBkColor($g_idPgFill, $C_ACC)
	$g_idPgCancel = _Btn("Cancel", 356, 122, 100, 28, $C_BTN, $C_BTN_HOT, $C_TXT)
	$g_bPgCancel = False
	GUISetState(@SW_SHOW, $g_hPG)
EndFunc   ;==>_PgOpen

Func _PgTitle($sTitle)
	GUICtrlSetData($g_idPgTitle, $sTitle)
EndFunc   ;==>_PgTitle

Func _PgSet($fPct, $sStatus)
	If $fPct < 0 Then $fPct = 0
	If $fPct > 100 Then $fPct = 100
	GUICtrlSetPos($g_idPgFill, 24, 100, _Max(1, Int(432 * $fPct / 100)), 10)
	GUICtrlSetData($g_idPgStat, $sStatus)
EndFunc   ;==>_PgSet

; keeps the window alive; True once the user asked to cancel
Func _PgPoll()
	Local $iMsg = GUIGetMsg()
	If $iMsg = $GUI_EVENT_CLOSE Or $iMsg = $g_idPgCancel Then $g_bPgCancel = True
	_Hover($g_hPG)
	Return $g_bPgCancel
EndFunc   ;==>_PgPoll

Func _PgClose()
	If $g_hPG Then GUIDelete($g_hPG)
	$g_hPG = 0
EndFunc   ;==>_PgClose

; one-time tables for the string based frame reader
Func _InitDecode()
	$g_tFrame = DllStructCreate("byte[" & $NBYTES & "]")
	For $v = 0 To 15
		$g_aBin4[$v] = BitAND(BitShift($v, 3), 1) & BitAND(BitShift($v, 2), 1) & BitAND(BitShift($v, 1), 1) & BitAND($v, 1) & ","
		$g_aHex1[$v] = Hex($v, 1)
	Next
	Local $sSet = "0123456789ABCDEF"
	$g_sDark = "[" & StringLeft($sSet, $g_iNibThr) & "]"
	$g_sBright = "[" & StringMid($sSet, $g_iNibThr + 1) & "]"
EndFunc   ;==>_InitDecode

; string of brightness nibbles (one hex char per cell) -> hex string of the packed bits (dark cell = 1)
Func _NibblesToHex($s)
	$s = StringRegExpReplace($s, $g_sDark, "1")
	$s = StringRegExpReplace($s, $g_sBright, "0")
	$s = StringRegExpReplace($s, "(....)", "\1,")                 ; 4 bits per token
	For $v = 0 To 15
		$s = StringReplace($s, $g_aBin4[$v], $g_aHex1[$v])        ; token -> one hex digit
	Next
	Return $s
EndFunc   ;==>_NibblesToHex

; $bin = COLS*ROWS gray bytes of one video frame.
; Returns 1 = new valid data frame stored, 2 = frame already known, 0 = not a usable data frame
Func _GrayFrame(ByRef $bin)
	; header from the first row only (cheap), so repeated frames cost almost nothing
	Local $s = StringRegExpReplace(Hex(BinaryMid($bin, 1, $COLS)), "(.).", "\1")      ; high nibble of every gray byte
	Local $sH = _NibblesToHex($s)
	Local $n = Dec(StringMid($sH, 1, 4)), $iN = Dec(StringMid($sH, 5, 4))
	If $iN = 0 Or $n >= $iN Or Mod($iN, $FEC_S) <> 0 Then Return 0
	If IsObj($g_oDict) And $g_oDict.Exists($n) Then Return 2

	$s = StringRegExpReplace(Hex($bin), "(.).", "\1")
	Local $sFrame = _NibblesToHex($s)
	If StringLen($sFrame) <> $NBYTES * 2 Then Return 0
	DllStructSetData($g_tFrame, 1, Binary("0x" & $sFrame))
	Local $iCrc = 0xFFFF, $i
	For $i = 1 To 8
		$iCrc = BitXOR(BitAND(BitShift($iCrc, -8), 0xFFFF), $g_aCrcTab[BitAND(BitXOR(BitShift($iCrc, 8), DllStructGetData($g_tFrame, 1, $i)), 0xFF)])
	Next
	For $i = $HDR + 1 To $NBYTES
		$iCrc = BitXOR(BitAND(BitShift($iCrc, -8), 0xFFFF), $g_aCrcTab[BitAND(BitXOR(BitShift($iCrc, 8), DllStructGetData($g_tFrame, 1, $i)), 0xFF)])
	Next
	If $iCrc <> DllStructGetData($g_tFrame, 1, 9) * 256 + DllStructGetData($g_tFrame, 1, 10) Then Return 0
	$g_oDict.Item($n) = StringMid($sFrame, $HDR * 2 + 1, $PAY * 2)
	$g_iN = $iN
	$g_iLen = Dec(StringMid($sFrame, 9, 8))
	Return 1
EndFunc   ;==>_GrayFrame

; guess the file type from the first bytes (hex string) for the output name
Func _SniffExt($sHex)
	If StringLeft($sHex, 6) = "494433" Then Return "mp3"
	If StringLeft($sHex, 2) = "FF" And BitAND(Dec(StringMid($sHex, 3, 2)), 0xE0) = 0xE0 Then Return "mp3"
	If StringLeft($sHex, 8) = "1A45DFA3" Then Return "webm"
	If StringLeft($sHex, 8) = "4F676753" Then Return "ogg"
	If StringLeft($sHex, 8) = "52494646" And StringMid($sHex, 17, 8) = "57415645" Then Return "wav"
	If StringLeft($sHex, 8) = "664C6143" Then Return "flac"
	If StringMid($sHex, 9, 8) = "66747970" Then Return "m4a"
	If StringLeft($sHex, 8) = "89504E47" Then Return "png"
	If StringLeft($sHex, 6) = "FFD8FF" Then Return "jpg"
	If StringLeft($sHex, 8) = "47494638" Then Return "gif"
	If StringLeft($sHex, 8) = "25504446" Then Return "pdf"
	If StringLeft($sHex, 8) = "504B0304" Then Return "zip"
	Local $c, $i, $bText = (StringLen($sHex) >= 8)
	For $i = 0 To Int(StringLen($sHex) / 2) - 1
		$c = Dec(StringMid($sHex, $i * 2 + 1, 2))
		If $c < 9 Or ($c > 13 And $c < 32) Or $c > 126 Then
			$bText = False
			ExitLoop
		EndIf
	Next
	Return $bText ? "txt" : "bin"
EndFunc   ;==>_SniffExt

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

; rebuild the $d missing data frames of the group starting at transmission index $n0
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

; assemble the file from what we have; lost data frames are rebuilt via parity where possible,
; frames that cannot be rebuilt are zero filled. Returns [file as hex, rebuilt frames, lost frames]
Func _Recover()
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
	Local $aRes[3] = [$sOut, $iFixed, $iLost]
	Return $aRes
EndFunc   ;==>_Recover

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

; text label (transparent background by default)
Func _T($sText, $x, $y, $w, $h, $iCol = 0xE8EAEE, $iBk = -2, $iStyle = -1)
	Local $id = GUICtrlCreateLabel($sText, $x, $y, $w, $h, $iStyle)
	GUICtrlSetColor($id, $iCol)
	GUICtrlSetBkColor($id, $iBk)
	Return $id
EndFunc   ;==>_T

; the BrAiNVC logo exactly like the web header: "Br" and "VC" in the text color, "AiN" in the accent color.
; Three labels are placed one after the other; the next one starts exactly where the text of the previous one ends.
Func _Logo($hWin, $x, $y, $iPt)
	GUISetFont($iPt, 700, 0, "Segoe UI")
	Local $aT[3] = ["Br", "AiN", "VC"], $aC[3] = [$C_TXT, $C_ACC, $C_TXT]
	Local $i, $id, $w, $aP, $cx = $x
	For $i = 0 To 2
		$id = _T($aT[$i], $cx, $y, -1, -1, $aC[$i])
		$w = _TextWidth($id, $aT[$i])
		If $w < 4 Then      ; could not measure the text: use the size of the label minus its padding
			$aP = ControlGetPos($hWin, "", $id)
			$w = IsArray($aP) ? $aP[2] - Round($iPt * 0.5) : Round($iPt * 0.8 * StringLen($aT[$i]))
		EndIf
		$cx += $w
	Next
	GUISetFont(9, 400, 0, "Segoe UI")
EndFunc   ;==>_Logo

; real pixel width of a text in the font of a control (no padding)
Func _TextWidth($id, $sText)
	Local $hWnd = GUICtrlGetHandle($id)
	Local $aDC = DllCall("user32.dll", "handle", "GetDC", "hwnd", $hWnd)
	If @error Or Not $aDC[0] Then Return 0
	Local $aFont = DllCall("user32.dll", "lresult", "SendMessageW", "hwnd", $hWnd, "uint", 0x31, "wparam", 0, "lparam", 0)   ; WM_GETFONT
	Local $aOld = DllCall("gdi32.dll", "handle", "SelectObject", "handle", $aDC[0], "handle", $aFont[0])
	Local $tSize = DllStructCreate("long cx;long cy")
	DllCall("gdi32.dll", "bool", "GetTextExtentPoint32W", "handle", $aDC[0], "wstr", $sText, "int", StringLen($sText), "struct*", $tSize)
	DllCall("gdi32.dll", "handle", "SelectObject", "handle", $aDC[0], "handle", $aOld[0])
	DllCall("user32.dll", "int", "ReleaseDC", "hwnd", $hWnd, "handle", $aDC[0])
	Return DllStructGetData($tSize, "cx")
EndFunc   ;==>_TextWidth

; flat button made of a label (colors can be set freely, hover handled in the message loop)
Func _Btn($sText, $x, $y, $w, $h, $iBase, $iHot, $iFg)
	Local $id = GUICtrlCreateLabel($sText, $x, $y, $w, $h, BitOR($SS_CENTER, $SS_CENTERIMAGE, $SS_NOTIFY))
	GUICtrlSetColor($id, $iFg)
	GUICtrlSetBkColor($id, $iBase)
	GUICtrlSetFont($id, 10, 700, 0, "Segoe UI")
	GUICtrlSetCursor($id, 0)
	$g_aBtnId[$g_iBtnN] = $id
	$g_aBtnBase[$g_iBtnN] = $iBase
	$g_aBtnHot[$g_iBtnN] = $iHot
	$g_iBtnN += 1
	Return $id
EndFunc   ;==>_Btn

Func _Section($sTitle, $y)
	Local $id = _T($sTitle, 24, $y, 532, 16, $C_DIM)
	GUICtrlSetFont($id, 8, 700, 0, "Segoe UI")
	$id = GUICtrlCreateLabel("", 24, $y + 19, 532, 1)
	GUICtrlSetBkColor($id, $C_LINE)
EndFunc   ;==>_Section

Func _Field($id)
	GUICtrlSetBkColor($id, $C_FIELD)
	GUICtrlSetColor($id, $C_TXT)
	Return $id
EndFunc   ;==>_Field

Func _Hover($hGui)
	Local $a = GUIGetCursorInfo($hGui), $iId = 0, $i
	If IsArray($a) Then $iId = $a[4]
	If $iId = $g_iHot Then Return
	For $i = 0 To $g_iBtnN - 1
		If $g_aBtnId[$i] = $g_iHot Then GUICtrlSetBkColor($g_aBtnId[$i], $g_aBtnBase[$i])
		If $g_aBtnId[$i] = $iId Then GUICtrlSetBkColor($g_aBtnId[$i], $g_aBtnHot[$i])
	Next
	$g_iHot = $iId
EndFunc   ;==>_Hover

Func _Toggle($id)
	If BitAND(GUICtrlRead($id), $GUI_CHECKED) Then
		GUICtrlSetState($id, $GUI_UNCHECKED)
	Else
		GUICtrlSetState($id, $GUI_CHECKED)
	EndIf
EndFunc   ;==>_Toggle

Func _Menu()
	Local $hM = GUICreate("BrAiNVC", 580, 606)
	GUISetBkColor($C_BG)
	GUISetFont(9, 400, 0, "Segoe UI")
	Local $id

	_Logo($hM, 24, 10, 22)
	_T("optical data link  -  file encoder / decoder", 26, 50, 520, 18, $C_DIM)
	Local $bEnc = _Btn("ENCODE      file  ->  video", 24, 82, 256, 54, $C_ACC, $C_ACC_HOT, 0x04202E)
	Local $bDec = _Btn("DECODE      video  ->  file", 300, 82, 256, 54, $C_ACC, $C_ACC_HOT, 0x04202E)

	_Section("FRAME FORMAT   (encoder and decoder must use the same values)", 156)
	_T("Grid (cells)", 24, 186, 150, 16, $C_DIM)
	$mGrid = _Field(GUICtrlCreateCombo("", 24, 204, 130, 22, $CBS_DROPDOWNLIST))
	_SetCombo($mGrid, "96x54|128x72|160x90|192x108", $COLS & "x" & $ROWS)
	GUICtrlSetTip($mGrid, "More cells = more data per frame, but smaller cells are harder to read after video compression.")
	_T("Data frames per group (K)", 190, 186, 170, 16, $C_DIM)
	$mK = _Field(GUICtrlCreateInput($FEC_K, 190, 204, 80, 22, $ES_NUMBER))
	GUICtrlSetTip($mK, "Larger K = less overhead, but a group needs more frames before it can be rebuilt.")
	_T("Parity frames per group (M)", 360, 186, 190, 16, $C_DIM)
	$mM = _Field(GUICtrlCreateInput($FEC_M, 360, 204, 80, 22, $ES_NUMBER))
	GUICtrlSetTip($mM, "Up to M lost frames per group of K+M are rebuilt. Overhead = M / (K+M).")

	_Section("ENCODE   (file -> video)", 250)
	_T("Video frame rate", 24, 280, 130, 16, $C_DIM)
	$mVfps = _Field(GUICtrlCreateCombo("", 24, 298, 100, 22, $CBS_DROPDOWNLIST))
	_SetCombo($mVfps, "30|60", $EXPORT_VFPS)
	_T("Data frames / s", 160, 280, 120, 16, $C_DIM)
	$mDfps = _Field(GUICtrlCreateInput($EXPORT_DATA_FPS, 160, 298, 80, 22, $ES_NUMBER))
	GUICtrlSetTip($mDfps, "Maximum = video fps / 2. For a screen scanner stay clearly below its scans per second; for decoding a file any value works.")
	_T("File repeats", 290, 280, 100, 16, $C_DIM)
	$mPass = _Field(GUICtrlCreateInput($EXPORT_PASSES, 290, 298, 70, 22, $ES_NUMBER))
	GUICtrlSetTip($mPass, "Repeat the whole file in the video (1-5), so lost frames get another chance.")
	_T("Beacon (s, 0 = off)", 400, 280, 150, 16, $C_DIM)
	$mBeacon = _Field(GUICtrlCreateInput($BEACON_SEC, 400, 298, 70, 22, $ES_NUMBER))
	GUICtrlSetTip($mBeacon, "Logo, then a 3-2-1 countdown before the data starts (0 = off).")
	$mRun = GUICtrlCreateCheckbox("", 24, 336, 18, 18)
	If $RUN_FFMPEG Then GUICtrlSetState($mRun, $GUI_CHECKED)
	Local $lRun = _T("Build the video with ffmpeg right away", 46, 337, 260, 18, $C_TXT, -2, $SS_NOTIFY)
	GUICtrlSetCursor($lRun, 0)
	$mOpen = GUICtrlCreateCheckbox("", 330, 336, 18, 18)
	If $OPEN_FOLDER Then GUICtrlSetState($mOpen, $GUI_CHECKED)
	Local $lOpen = _T("Open the folder when done", 352, 337, 200, 18, $C_TXT, -2, $SS_NOTIFY)
	GUICtrlSetCursor($lOpen, 0)

	_Section("DECODE   (video -> file)", 372)
	_T("Brightness threshold (1-15)", 24, 402, 180, 16, $C_DIM)
	$mThr = _Field(GUICtrlCreateInput($g_iNibThr, 24, 420, 80, 22, $ES_NUMBER))
	GUICtrlSetTip($mThr, "Cells darker than this (in 16ths of full brightness) count as black. 8 = middle.")
	_T("Frames/s to read (0 = every video frame)", 190, 402, 280, 16, $C_DIM)
	$mRead = _Field(GUICtrlCreateInput($READ_FPS, 190, 420, 80, 22, $ES_NUMBER))
	GUICtrlSetTip($mRead, "0 reads every frame of the video (safest). A lower value skips frames and is faster, but may miss short frames.")

	$mInfo = _T("", 24, 464, 532, 58, $C_DIM)
	Local $sFf = _FindFfmpeg()
	If $sFf = "" Then
		_T("ffmpeg: NOT FOUND - put ffmpeg.exe next to this script", 24, 540, 280, 18, $C_BAD)
	ElseIf $sFf = "ffmpeg" Then
		_T("ffmpeg: found in PATH", 24, 540, 280, 18, $C_OK)
	Else
		_T("ffmpeg: found next to the script", 24, 540, 280, 18, $C_OK)
	EndIf
	Local $bAbout = _Btn("About", 318, 534, 110, 28, $C_BTN, $C_BTN_HOT, $C_TXT)
	Local $bDef = _Btn("Defaults", 440, 534, 116, 28, $C_BTN, $C_BTN_HOT, $C_TXT)
	Local $lDisc = _T("Experimental, provided AS IS. Private, non-commercial use only. Click here for the full disclaimer.", 24, 578, 532, 16, $C_WARN, -2, $SS_NOTIFY)
	GUICtrlSetFont($lDisc, 8, 400, 0, "Segoe UI")
	GUICtrlSetCursor($lDisc, 0)
	GUISetState(@SW_SHOW)

	Local $iMsg, $hTm = TimerInit()
	_MenuInfo()
	While 1
		$iMsg = GUIGetMsg()
		Switch $iMsg
			Case $GUI_EVENT_CLOSE
				Exit
			Case $bEnc
				_MenuStart("enc")
			Case $bDec
				_MenuStart("dec")
			Case $bDef
				_MenuDefaults()
			Case $bAbout, $lDisc
				_About($hM)
			Case $lRun
				_Toggle($mRun)
			Case $lOpen
				_Toggle($mOpen)
		EndSwitch
		_Hover($hM)
		If TimerDiff($hTm) > 300 Then
			_MenuInfo()
			$hTm = TimerInit()
		EndIf
	WEnd
EndFunc   ;==>_Menu


; =====================================================================
; About window: links and the disclaimer
; =====================================================================
Func _DisclaimerText()
	Local $s = "BrAiNVC is intended strictly for private, personal, and non-commercial use." & @CRLF & @CRLF & _
			"The use of BrAiNVC by companies, commercial organizations, military organizations, government agencies, public authorities, or other institutional entities is NOT permitted without prior explicit written permission from the project author." & @CRLF & @CRLF & _
			"Such organizations must contact the project author and obtain approval before using, deploying, integrating, or distributing BrAiNVC." & @CRLF & @CRLF & _
			"SECURITY NOTICE" & @CRLF & _
			"BrAiNVC is an experimental project and is provided AS IS, without any guarantees regarding security, reliability, availability, or data integrity." & @CRLF & @CRLF & _
			"The software has not been designed, audited, or certified for professional, commercial, military, governmental, or security-critical environments." & @CRLF & @CRLF & _
			"In particular:" & @CRLF & _
			"- No guarantee of confidentiality or secure data transmission is provided." & @CRLF & _
			"- No protection against interception, manipulation, or unauthorized access is guaranteed." & @CRLF & _
			"- The software must not be used to transmit sensitive, confidential, classified, or otherwise critical information." & @CRLF & _
			"- BrAiNVC must not be considered a secure communication system." & @CRLF & @CRLF & _
			"NO WARRANTY / LIMITATION OF LIABILITY" & @CRLF & _
			"The software is provided without any express or implied warranty. The author accepts no responsibility for damages, data loss, security incidents, or other consequences resulting from the use or misuse of this project, to the extent permitted by applicable law." & @CRLF & @CRLF & _
			"By using BrAiNVC, you acknowledge and accept these limitations and usage restrictions." & @CRLF & @CRLF & _
			"If you represent a company, military organization, government agency, or other institution and wish to use BrAiNVC, please contact the project author for prior authorization."
	Return $s
EndFunc   ;==>_DisclaimerText

Func _About($hParent)
	Local $iN0 = $g_iBtnN, $iMsg, $id
	GUISetState(@SW_DISABLE, $hParent)
	Local $hA = GUICreate("About BrAiNVC", 580, 580, -1, -1, BitOR($WS_CAPTION, $WS_SYSMENU), -1, $hParent)
	GUISetBkColor($C_BG, $hA)
	GUISetFont(9, 400, 0, "Segoe UI")
	_Logo($hA, 24, 10, 22)
	_T("optical data link  -  file encoder / decoder  (the live scanner is in the web version)", 26, 50, 532, 18, $C_DIM)
	_T("Experimental test mode - NOT SAFE. Please follow the usage restrictions below.", 26, 72, 532, 18, $C_WARN)

	_Section("LINKS", 104)
	_T("GitHub", 24, 132, 90, 18, $C_DIM)
	Local $lGit = _T($APP_URL, 120, 132, 436, 18, $C_ACC, -2, $SS_NOTIFY)
	GUICtrlSetFont($lGit, 9, 400, 4, "Segoe UI")
	GUICtrlSetCursor($lGit, 0)
	_T("Web version", 24, 156, 90, 18, $C_DIM)
	Local $lWeb = _T($APP_WEB, 120, 156, 436, 18, $C_ACC, -2, $SS_NOTIFY)
	GUICtrlSetFont($lWeb, 9, 400, 4, "Segoe UI")
	GUICtrlSetCursor($lWeb, 0)

	_Section("DISCLAIMER AND USAGE RESTRICTIONS", 194)
	Local $e = GUICtrlCreateEdit(_DisclaimerText(), 24, 224, 532, 290, BitOR($ES_READONLY, $ES_MULTILINE, $WS_VSCROLL))
	GUICtrlSetBkColor($e, $C_FIELD)
	GUICtrlSetColor($e, $C_TXT)
	Local $bClose = _Btn("Close", 456, 526, 100, 30, $C_ACC, $C_ACC_HOT, 0x04202E)
	GUISetState(@SW_SHOW, $hA)
	GUICtrlSendMsg($e, $EM_SETSEL, 0, 0)
	While 1
		$iMsg = GUIGetMsg()
		Switch $iMsg
			Case $GUI_EVENT_CLOSE, $bClose
				ExitLoop
			Case $lGit
				ShellExecute($APP_URL)
			Case $lWeb
				ShellExecute($APP_WEB)
		EndSwitch
		_Hover($hA)
	WEnd
	GUISetState(@SW_ENABLE, $hParent)
	GUIDelete($hA)
	GUISwitch($hParent)
	$g_iBtnN = $iN0
	$g_iHot = 0
	WinActivate($hParent)
EndFunc   ;==>_About

; live estimate under the fields
Func _MenuInfo()
	Local $aG = StringSplit(GUICtrlRead($mGrid), "x", 2)
	If UBound($aG) < 2 Then Return
	Local $c = Int($aG[0]), $r = Int($aG[1])
	Local $iPay = Int($c * $r / 8) - 10
	Local $k = _Num($mK, 1, 64), $m = _Num($mM, 1, 8)
	Local $iV = Int(GUICtrlRead($mVfps)), $fD = _Num($mDfps, 1, Int($iV / 2))
	Local $iEx = Int(1920 / $c)
	GUICtrlSetData($mInfo, "Frame: " & Int($c * $r / 8) & " bytes (" & $iPay & " payload), error correction overhead " & Round($m / ($k + $m) * 100) & " %" & @CRLF & _
			"At " & $fD & " data frames/s: about " & Round($fD * $iPay * $k / ($k + $m) / 1024, 1) & " kB/s of payload" & @CRLF & _
			"Video: " & $c * $iEx & "x" & $r * $iEx & " (cell " & $iEx & " px), " & $iV & " fps")
EndFunc   ;==>_MenuInfo

Func _MenuSave()
	Local $aG = StringSplit(GUICtrlRead($mGrid), "x", 2)
	If UBound($aG) = 2 Then
		IniWrite($INI, $SEC, "Cols", $aG[0])
		IniWrite($INI, $SEC, "Rows", $aG[1])
	EndIf
	IniWrite($INI, $SEC, "FecK", _Num($mK, 1, 64))
	IniWrite($INI, $SEC, "FecM", _Num($mM, 1, 8))
	Local $iV = Int(GUICtrlRead($mVfps))
	IniWrite($INI, $SEC, "VideoFps", $iV)
	IniWrite($INI, $SEC, "DataFps", _Num($mDfps, 1, Int($iV / 2)))
	IniWrite($INI, $SEC, "Passes", _Num($mPass, 1, 5))
	IniWrite($INI, $SEC, "BeaconSec", _Num($mBeacon, 0, 30))
	IniWrite($INI, $SEC, "RunFfmpeg", (GUICtrlRead($mRun) = $GUI_CHECKED) ? 1 : 0)
	IniWrite($INI, $SEC, "OpenFolder", (GUICtrlRead($mOpen) = $GUI_CHECKED) ? 1 : 0)
	IniWrite($INI, $SEC, "Thr", _Num($mThr, 1, 15))
	IniWrite($INI, $SEC, "ReadFps", _Num($mRead, 0, 240))
EndFunc   ;==>_MenuSave

; save, then run the chosen mode in a new process (so every setting, also grid / FEC, takes effect) and close the menu
Func _MenuStart($sMode)
	_MenuSave()
	_Relaunch($sMode & " menu")
	Exit
EndFunc   ;==>_MenuStart

Func _Relaunch($sArgs)
	Local $sCmd = @Compiled ? '"' & @ScriptFullPath & '"' : '"' & @AutoItExe & '" "' & @ScriptFullPath & '"'
	Run($sCmd & " " & $sArgs, @ScriptDir)
EndFunc   ;==>_Relaunch

Func _MenuDefaults()
	_SetCombo($mGrid, "96x54|128x72|160x90|192x108", "160x90")
	GUICtrlSetData($mK, 8)
	GUICtrlSetData($mM, 2)
	_SetCombo($mVfps, "30|60", "60")
	GUICtrlSetData($mDfps, 10)
	GUICtrlSetData($mPass, 2)
	GUICtrlSetData($mBeacon, 5)
	GUICtrlSetState($mRun, $GUI_CHECKED)
	GUICtrlSetState($mOpen, $GUI_CHECKED)
	GUICtrlSetData($mThr, 8)
	GUICtrlSetData($mRead, 0)
EndFunc   ;==>_MenuDefaults
