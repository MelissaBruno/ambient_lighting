#include "FastLED.h"
 
#define NUM_LEDS 25
#define SPEED 115200

int ledPIN = 11;

CRGB leds[NUM_LEDS];
uint8_t * ledsRaw = (uint8_t *)leds;
 
static const uint8_t magic[] = {'M','e','l'};
#define MAGICSIZE  sizeof(magic)
#define HEADERSIZE (MAGICSIZE + 3)
 
#define MODE_HEADER 0
#define MODE_DATA   2
 
// If no serial data is received for a while, the LEDs are shut off
// automatically.
static const unsigned long serialTimeout = 150000; // 150 seconds
 
void setup()
{
  FastLED.addLeds<WS2801, RGB>(leds, NUM_LEDS);

  #define OFF_PIN 6
  #define AMBIENT_PIN 7
  #define WHITE_PIN A0
  #define COLOR_PIN A1

  int offSwitchMode = 0;
  boolean offSwitch = false;  

  int ambientSwitchMode = 0;
  boolean ambientSwitch = false;

  int whiteState = 0;
  boolean whiteSwitch = false;

  int colorState = 0;
  boolean colorSwitch = false;

  pinMode(OFF_PIN, INPUT);
  pinMode(AMBIENT_PIN, INPUT);
  pinMode(WHITE_PIN, INPUT);
  pinMode(COLOR_PIN, INPUT);
    
  uint8_t
    buffer[256],
    indexIn = 0,
    indexOut = 0,
    mode = MODE_HEADER,
    hi, lo, chk, i, spiFlag;
  int16_t
    bytesBuffered = 0,
    hold = 0,
    c;
  int32_t
    bytesRemaining;
  unsigned long
    startTime,
    lastByteTime,
    lastAckTime,
    t;
  int32_t outPos = 0;
 
  Serial.begin(SPEED);
 
  Serial.print("Mel\n"); // Send ACK string to host
 
  startTime    = micros();
  lastByteTime = lastAckTime = millis();
 
  // loop() is avoided as even that small bit of function overhead
  // has a measurable impact on this code's overall throughput.
  
  for(;;) {
    offSwitchMode = digitalRead(OFF_PIN);
    ambientSwitchMode = digitalRead(AMBIENT_PIN);
    whiteState = analogRead(WHITE_PIN);
    colorState = analogRead(COLOR_PIN);

    if(offSwitchMode == HIGH){
      offSwitch = true;
      ambientSwitch = false;
      whiteSwitch = false;
      colorSwitch = false;
    }
    if(ambientSwitchMode == HIGH){
      offSwitch = false;
      ambientSwitch =  true;
      whiteSwitch = false;
      colorSwitch = false;
    }
    if(whiteState > 10){
      offSwitch = false;
      ambientSwitch =  false;
      whiteSwitch = true;
      colorSwitch = false;
    }
    if(colorState > 10){
      offSwitch = false;
      ambientSwitch =  false;
      whiteSwitch = false;
      colorSwitch = true;
    }

    if(ambientSwitch == true){
      
      // Implementation is a simple finite-state machine.
      // Regardless of mode, check for serial input each time:
      t = millis();
      if((bytesBuffered < 256) && ((c = Serial.read()) >= 0)) {
        buffer[indexIn++] = c;
        bytesBuffered++;
        lastByteTime = lastAckTime = t; // Reset timeout counters
      } else {
        // No data received.  If this persists, send an ACK packet
        // to host once every second to alert it to our presence.
        if((t - lastAckTime) > 1000) {
          Serial.print("Mel\n"); // Send ACK string to host
          lastAckTime = t; // Reset counter
        }
        // If no data received for an extended time, turn off all LEDs.
        if((t - lastByteTime) > serialTimeout) {
          memset(leds, 0,  NUM_LEDS * sizeof(struct CRGB)); //filling Led array by zeroes
          FastLED.show();
          lastByteTime = t; // Reset counter
        }
      }
  
      switch(mode) {
   
       case MODE_HEADER:
   
        // In header-seeking mode.  Is there enough data to check?
        if(bytesBuffered >= HEADERSIZE) {
          // Indeed.  Check for a 'magic word' match.
          for(i=0; (i<MAGICSIZE) && (buffer[indexOut++] == magic[i++]););
          if(i == MAGICSIZE) {
            // Magic word matches.  Now how about the checksum?
            hi  = buffer[indexOut++];
            lo  = buffer[indexOut++];
            chk = buffer[indexOut++];
            if(chk == (hi ^ lo ^ 0x55)) {
              // Checksum looks valid.  Get 16-bit LED count, add 1
              // (# LEDs is always > 0) and multiply by 3 for R,G,B.
              bytesRemaining = 3L * (256L * (long)hi + (long)lo + 1L);
              bytesBuffered -= 3;
              outPos = 0;
              memset(leds, 0,  NUM_LEDS * sizeof(struct CRGB));
              mode           = MODE_DATA; // Proceed to latch wait mode
            } else {
              // Checksum didn't match; search resumes after magic word.
              indexOut  -= 3; // Rewind
            }
          } // else no header match.  Resume at first mismatched byte.
          bytesBuffered -= i;
        }
        break;
   
       case MODE_DATA:
   
        if(bytesRemaining > 0) {
          if(bytesBuffered > 0) {
            if (outPos < sizeof(leds))
              ledsRaw[outPos++] = buffer[indexOut++];   // Issue next byte
            bytesBuffered--;
            bytesRemaining--;
          }
          // If serial buffer is threatening to underrun, start
          // introducing progressively longer pauses to allow more
          // data to arrive (up to a point).
        } else {
          // End of data -- issue latch:
          startTime  = micros();
          mode       = MODE_HEADER; // Begin next header search
          FastLED.show();
        }
      } // end switch
    } // end ambientMode
    
    if(offSwitch == true) {
      memset(leds, 0,  NUM_LEDS * sizeof(struct CRGB)); //filling Led array by zeroes
      FastLED.show();
    }
    if(whiteSwitch == true){
      for(int i = 0; i < NUM_LEDS; i++){
        leds[i] = CRGB(whiteState/5,whiteState/5,whiteState/5);
        FastLED.show();
      }
    }
    if(colorSwitch == true){
      if(colorState < 341){
        for(int i = 0; i < NUM_LEDS; i++){
          leds[i] = CRGB(colorState/3,0,0);
          FastLED.show();
        }
      }
    if(colorState > 341 && colorState < 682){
        for(int i = 0; i < NUM_LEDS; i++){
          leds[i] = CRGB(0,colorState/3,0);
          FastLED.show();
        }
      }
      if(colorState >682){
        for(int i = 0; i < NUM_LEDS; i++){
          leds[i] = CRGB(0,0,colorState/3);
          FastLED.show();
        }
      }
    }
    
  } // end for(;;)
} // end Setup
 
void loop()
{
  // Not used.  See note in setup() function.
}
