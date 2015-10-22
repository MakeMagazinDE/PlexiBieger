program PLEXITIMER;

{$NOSHADOW}
{ $WG}                     {global Warnings off}

Device = mega328, VCC=3;
{$BOOTRST $03C00}         {Reset Jump to $03C00}


Import SysTick, SysLEDblink, SerPort, BeepPort, ADCport, RTClock, SPIdriver;
//
From System Import LongInt;


Define
  ProcClock      = 16000000;       {Hertz}
  SysTick        = 10;             {msec}
  StackSize      = $0064, iData;
  FrameSize      = $0064, iData;
  SerPort        = 57600, Stop1;    {Baud, StopBits|Parity}
  RxBuffer       = 16, iData;
  TxBuffer       = 16, iData;
  SysLedBlink    = 10;              {SysTicks}
  SysLedBlink0   = PortB, 0, high;      // PIN IO8
  ADCchans       = [1,2], iData, int2;  // ADC-MPX auf PC0 = AN0 = Kanal 1
  ADCpresc       = 64;
  RTClock        = iData, Time;
  RTCsource      = SysTick;
  BeepPort       = PortD, 7;

  SPIorder    = MSB;
  SPIcpol     = 1;
  SPIcpha     = 1;
  SPIpresc    = 1;       // presc = 0..3 -> 4/16/64/128
  SPI_SS = false;        // PB2 = IO10

Implementation

{$IDATA}

{--------------------------------------------------------------}
{ Type Declarations }

type
 t_state = (s_off, s_heatup, s_pause, s_warm, s_bend, s_cool, s_endbeep, s_error);

{--------------------------------------------------------------}
{ Const Declarations }
const
  // a=$10, b=$02, c=$08, d=$40, e=$80 ..
  c_digit_table: array[0..9] of byte = ($DB, $0A, $F2, $7A, $2B, $79, $F9, $1A, $FB, $7B);
  c_cooldown_seconds: Integer = 60;
  c_bendwait_seconds: Integer = 15;
  c_minimal_seconds: Integer = 30;
  c_minimal_pause: Integer = 10;

{--------------------------------------------------------------}
{ Var Declarations }
var
{$PDATA}
  BEEPER[@PortD,7]: Bit;        // PIN IO7
  HEATER_UPPER[@PortD,6]: Bit;  // PIN IO6
  HEATER_LOWER[@PortD,5]: Bit;  // PIN IO5
  FANS[@PortD,4]: Bit;          // PIN IO4
  HEATBAR_UP[@PinD,3]: Bit;     // PIN IO3
//  _STARTBTN[@PinD,2]: Bit;    // PIN IO2
  OHO_SS[@PortB,2]: Bit;        // PIN IO10

{$DATA}
var
  i, j, k : Byte;
{$IDATA}

var
  HeaterCount, HeaterPWM: Byte;
  HeaterPot, TimerSeconds: Integer;
  TimeVal, TimeValHeatup, TimeValWarming: Integer;
  OldHeatBarUp, HeaterOn: Boolean;
  State: t_state;
  LEDdata: LongInt;  // EEZZMM-- "M.ZE"
  digit_1[@LEDdata+3]: byte;
  digit_2[@LEDdata+2]: byte;
  digit_3[@LEDdata+1]: byte;

{--------------------------------------------------------------}
{ functions }


procedure RTCtickSecond;
begin
  dectolim(TimerSeconds, 0);
  HeaterOn:= HeaterCount < HeaterPWM;
  inc(HeaterCount);
  if HeaterCount >= 10 then
    HeaterCount:= 0;
  endif;
end;

procedure InitPorts;
begin
  DDRD:=  %11110000;
  PortD:= %00001000;
  DDRB:=  %00101101;
  PortB:= %00010100;
  ADMUX:= ADMUX or $40;
end;

procedure ShiftOut;
begin
  SPIoutLong(not LEDdata);  // neg. Logik
  OHO_SS:= true;
  nop;
  OHO_SS:= false;
end;

procedure Display(my_time: Integer);
var
  my_Minutes, my_Seconds: Byte;
begin
  my_Minutes:= byte(my_time div 60);
  my_Seconds:= byte(my_time mod 60);
  digit_3:= c_digit_table[my_Minutes] or $04;  // Minuten mit Punkt
  digit_2:= c_digit_table[my_Seconds div 10];  // Zehner Sekunden
  digit_1:= c_digit_table[my_Seconds mod 10];  // Einer  Sekunden
  ShiftOut;
end;

{--------------------------------------------------------------}
{ Main Program }
{$IDATA}

begin
  InitPorts;
  EnableInts;
  SysLEDenable(true);
  SysLEDOn(0);
  Beepout(2000, 20);
  SysLEDOff(0);

  OldHeatBarUp:= HEATBAR_UP;
  State:= s_off;
  loop
    case state of
      s_off:
        TimeVal:= Integer((GetADC(1) shr 2));
        TimeValHeatup:=  MulDivInt(TimeVal,80,255) + c_minimal_seconds; // erstes Aufheizen
        TimeValWarming:= MulDivInt(TimeVal,160,255) + c_minimal_seconds; // Durchwärmen
        HeaterPot:= Integer(GetADC(2) shr 2);
        HeaterPWM:= MulDivByte(lo(HeaterPot),10,255);  // Warmhalten Heizleistung PWM
        FANS:= false;
        HEATER_LOWER:= false;
        HEATER_UPPER:= false;
        if (not HEATBAR_UP) then
          if OldHeatBarUp then
            TimerSeconds:= TimeValHeatup;
            BeepStepLH;
            state:= s_heatup;
          else
            if (HeaterCount and 1) = 0 then
              LEDdata:= $A0A0F100;  // "Err"
            else
              LEDdata:= $B3CB0000;  // "UP"
            endif;
            ShiftOut;
          endif;
        else
          Display(TimeValWarming + TimeValHeatup);
        endif;
        |
      s_heatup:
        FANS:= false;
        HEATER_LOWER:= true;
        HEATER_UPPER:= true;
        SysLEDFlashOff(0);
        SysLEDOn(0);
        Display(TimerSeconds);
        if HEATBAR_UP then
          state:= s_error;
        elsif TimerSeconds = 0 then
          BeepStepHL;
          TimerSeconds:= c_minimal_pause;
          state:= s_pause;
        endif;
        |
      s_pause:
        FANS:= false;
        HEATER_LOWER:= false;
        HEATER_UPPER:= HeaterOn;
        SysLEDOff(0);
        Display(TimerSeconds);
        if HEATBAR_UP then
          state:= s_error;
        elsif TimerSeconds = 0 then
          Beepout(2000, 10);
          TimerSeconds:= TimeValWarming;
          HeaterCount:= 0;
          state:= s_warm;
        endif;
        |
      s_warm:
        FANS:= false;
        HEATER_LOWER:= HeaterOn;
        HEATER_UPPER:= true;
        SysLEDOnOff(0, HeaterOn);
        Display(TimerSeconds);
        if HEATBAR_UP then
          Beepout(2000, 10);
          TimerSeconds:= c_bendwait_seconds;
          state:= s_bend;
        elsif TimerSeconds = 0 then
          TimerSeconds:= 5;    // Beep Time
          LEDdata:= $EAA8F100; // "End"
          ShiftOut;
          state:= s_endbeep;
        endif;
        |
      s_endbeep:
        FANS:= false;
        HEATER_LOWER:= HeaterOn;
        HEATER_UPPER:= false;
        if HEATBAR_UP then  // warten bis Heizleiste angehoben
          TimerSeconds:= c_bendwait_seconds;
          state:= s_bend;
        elsif TimerSeconds > 0 then
          BeepChirpL(5);
          BeepChirpH(5);
        endif;
        |
      s_bend:
        FANS:= false;
        HEATER_LOWER:= false;
        HEATER_UPPER:= false;
        if not HEATBAR_UP then
          BeepStepHL;
          TimerSeconds:= TimeValHeatup; // kurze Verlängerung
          state:= s_warm;
        endif;
        if TimerSeconds = 0 then
          TimerSeconds:= c_cooldown_seconds;
          state:= s_cool;
        endif;
        |
      s_cool:
        FANS:= true;
        HEATER_LOWER:= false;
        HEATER_UPPER:= false;
        Display(TimerSeconds);
        if not HEATBAR_UP then
          BeepStepHL;
          TimerSeconds:= TimeValHeatup; // kurze Verlängerung
          state:= s_warm;
        endif;
        if TimerSeconds = 0 then
          BeepChirpL(15);
          state:= s_off;
        endif;
        |
      s_error:
        HEATER_LOWER:= false;
        HEATER_UPPER:= false;
        LEDdata:= $A0A0F100;  // "Err"
        ShiftOut;
        BeepSiren(1,3);
        SysLEDFlashOn(0);
        mdelay(1000);
        state:= s_off;
        |
    endcase;
    OldHeatBarUp:= HEATBAR_UP;
    mdelay(50);
  endloop;

end.

