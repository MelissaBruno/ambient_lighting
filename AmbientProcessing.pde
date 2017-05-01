import java.awt.*;
import java.awt.image.*;
import processing.serial.*;
 
static int minBrightness = 120;
static int fade = 75;  
 
static final int timeout = 5000; // 5 seconds

/*
 * Monitor array; 9 LED's are on the top and bottom, and 6 LED's
 * are on the sides.
 */
static final int monitor[][] = new int[][] {
   {0,9,6}
};

/*
 * LED array; first number is the monitor, middle number is the X coordinate,
 * and third is the Y coordinate. Starts at the beginning of LED strand, in the
 * bottom left when FACING the LED's (layout is shown on Github wiki)
 */
static final int leds[][] = new int[][] {
  {0,3,5}, {0,2,5}, {0,1,5}, {0,0,5}, {0,0,4}, {0,0,3}, {0,0,2}, {0,0,1},
  {0,0,0}, {0,1,0}, {0,2,0}, {0,3,0}, {0,4,0}, {0,5,0}, {0,6,0}, {0,7,0},
  {0,8,0}, {0,8,1}, {0,8,2}, {0,8,3}, {0,8,4}, {0,8,5}, {0,7,5}, {0,6,5},
  {0,5,5}
};

byte[]           serialData  = new byte[6 + leds.length * 3];
int[][]          ledColor    = new int[leds.length][3],
                 prevColor   = new int[leds.length][3];
byte[][]         gamma       = new byte[256][3];
int              nDisplays   = monitor.length;
Robot[]          bot         = new Robot[monitor.length];
Rectangle[]      dispBounds  = new Rectangle[monitor.length],
                 ledBounds;  // Alloc'd only if per-LED captures
int[][]          pixelOffset = new int[leds.length][256],
                 screenData; // Alloc'd only if full-screen captures
PImage[]         preview     = new PImage[monitor.length];
Serial           port;
DisposeHandler   dh; // For disabling LEDs on exit

// INITIALIZATION ------------------------------------------------------------

void setup() {
  GraphicsEnvironment     ge;
  GraphicsConfiguration[] gc;
  GraphicsDevice[]        gd;
  int                     d, i, totalWidth, maxHeight, row, col, rowOffset;
  int[]                   x = new int[16], y = new int[16];
  float                   f, range, step, start;

  dh = new DisposeHandler(this); // Init DisposeHandler ASAP

  port = new Serial(this, Serial.list()[1], 115200);      //Open serial port, ***may need to be changed before demo***

  // Initialize screen capture code for each display's dimensions.
  dispBounds = new Rectangle[monitor.length];
  screenData = new int[monitor.length][];
  ge = GraphicsEnvironment.getLocalGraphicsEnvironment();
  gd = ge.getScreenDevices();
  if(nDisplays > gd.length) nDisplays = gd.length;
  totalWidth = maxHeight = 0;
  for(d=0; d<nDisplays; d++) { // For each display...
    try {
      bot[d] = new Robot(gd[monitor[d][0]]);
    }
    catch(AWTException e) {
      System.out.println("new Robot() failed");
      continue;
    }
    gc              = gd[monitor[d][0]].getConfigurations();
    dispBounds[d]   = gc[0].getBounds();
    dispBounds[d].x = dispBounds[d].y = 0;
    preview[d]      = createImage(monitor[d][1], monitor[d][2], RGB);
    preview[d].loadPixels();
    totalWidth     += monitor[d][1];
    if(d > 0) totalWidth++;
    if(monitor[d][2] > maxHeight) maxHeight = monitor[d][2];
  }

  // Precompute locations of every pixel to read when downsampling.
  // Saves a bunch of math on each frame, at the expense of a chunk
  // of RAM.  Number of samples is now fixed at 256; this allows for
  // some crazy optimizations in the downsampling code.
  for(i=0; i<leds.length; i++) { // For each LED...
    d = leds[i][0]; // Corresponding display index

    // Precompute columns, rows of each sampled point for this LED
    range = (float)dispBounds[d].width / (float)monitor[d][1];
    step  = range / 16.0;
    start = range * (float)leds[i][1] + step * 0.5;
    for(col=0; col<16; col++) x[col] = (int)(start + step * (float)col);
    range = (float)dispBounds[d].height / (float)monitor[d][2];
    step  = range / 16.0;
    start = range * (float)leds[i][2] + step * 0.5;
    for(row=0; row<16; row++) y[row] = (int)(start + step * (float)row);

      // Get offset to each pixel within full screen capture
      for(row=0; row<16; row++) {
        for(col=0; col<16; col++) {
          pixelOffset[i][row * 16 + col] =
            y[row] * dispBounds[d].width + x[col];
        }
      }
  }

  for(i=0; i<prevColor.length; i++) {
    prevColor[i][0] = prevColor[i][1] = prevColor[i][2] =
      minBrightness / 3;
  }


  // A special header / magic word is expected by the corresponding LED
  // streaming code running on the Arduino.  This only needs to be initialized
  // once (not in draw() loop) because the number of LEDs remains constant:
  serialData[0] = 'M';                              // Magic word
  serialData[1] = 'e';
  serialData[2] = 'l';
  serialData[3] = (byte)((leds.length - 1) >> 8);   // LED count high byte
  serialData[4] = (byte)((leds.length - 1) & 0xff); // LED count low byte
  serialData[5] = (byte)(serialData[3] ^ serialData[4] ^ 0x55); // Checksum

  // Pre-compute gamma correction table for LED brightness levels:
  for(i=0; i<256; i++) {
    f           = pow((float)i / 255.0, 2.8);
    gamma[i][0] = (byte)(f * 255.0);
    gamma[i][1] = (byte)(f * 240.0);
    gamma[i][2] = (byte)(f * 220.0);
  }
}

// Open and return serial connection to Arduino running LEDstream code.  This
// attempts to open and read from each serial device on the system, until the
// matching "Ada\n" acknowledgement string is found.  Due to the serial
// timeout, if you have multiple serial devices/ports and the Arduino is late
// in the list, this can take seemingly forever...so if you KNOW the Arduino
// will always be on a specific port (e.g. "COM6"), you might want to comment
// out most of this to bypass the checks and instead just open that port
// directly!  (Modify last line in this method with the serial port name.)

Serial openPort() {
  String[] ports;
  String   ack;
  int      i, start;
  Serial   s;

  ports = Serial.list(); // List of all serial ports/devices on system.

  for(i=0; i<ports.length; i++) { // For each serial port...
    System.out.format("Trying serial port %s\n",ports[i]);
    try {
      s = new Serial(this, ports[i], 115200);
    }
    catch(Exception e) {
      // Can't open port, probably in use by other software.
      continue;
    }
    // Port open...watch for acknowledgement string...
    start = millis();
    while((millis() - start) < timeout) {
      if((s.available() >= 4) &&
        ((ack = s.readString()) != null) &&
        ack.contains("Mel\n")) {
          return s; // Got it!
      }
    }
    // Connection timed out.  Close port and move on to the next.
    s.stop();
  }

  // Didn't locate a device returning the acknowledgment string.
  // Maybe it's out there but running the old LEDstream code, which
  // didn't have the ACK.  Can't say for sure, so we'll take our
  // changes with the first/only serial device out there...
  return new Serial(this, ports[0], 115200);
}


// PER_FRAME PROCESSING ------------------------------------------------------

void draw () {
  BufferedImage img;
  int           d, i, j, o, c, weight, rb, g, sum, deficit, s2;
  int[]         pxls, offs;

    // Capture each screen in the displays array.
    for(d=0; d<nDisplays; d++) {
      img = bot[d].createScreenCapture(dispBounds[d]);
      // Get location of source pixel data
      screenData[d] =
        ((DataBufferInt)img.getRaster().getDataBuffer()).getData();
    }
  

  weight = 257 - fade; // 'Weighting factor' for new frame vs. old
  j      = 6;          // Serial led data follows header / magic word

  // This computes a single pixel value filtered down from a rectangular
  // section of the screen.  While it would seem tempting to use the native
  // image scaling in Processing/Java, in practice this didn't look very
  // good -- either too pixelated or too blurry, no happy medium.  So
  // instead, a "manual" downsampling is done here.  In the interest of
  // speed, it doesn't actually sample every pixel within a block, just
  // a selection of 256 pixels spaced within the block...the results still
  // look reasonably smooth and are handled quickly enough for video.

  for(i=0; i<leds.length; i++) {  // For each LED...
    d = leds[i][0]; // Corresponding display index
      // Get location of source data from prior full-screen capture:
      pxls = screenData[d];
    offs = pixelOffset[i];
    rb = g = 0;
    for(o=0; o<256; o++) {
      c   = pxls[offs[o]];
      rb += c & 0x00ff00ff; // Bit trickery: R+B can accumulate in one var
      g  += c & 0x0000ff00;
    }

    // Blend new pixel value with the value from the prior frame
    ledColor[i][0]  = (short)((((rb >> 24) & 0xff) * weight +
                               prevColor[i][0]     * fade) >> 8);
    ledColor[i][1]  = (short)(((( g >> 16) & 0xff) * weight +
                               prevColor[i][1]     * fade) >> 8);
    ledColor[i][2]  = (short)((((rb >>  8) & 0xff) * weight +
                               prevColor[i][2]     * fade) >> 8);

    // Boost pixels that fall below the minimum brightness
    sum = ledColor[i][0] + ledColor[i][1] + ledColor[i][2];
    if(sum < minBrightness) {
      if(sum == 0) { // To avoid divide-by-zero
        deficit = minBrightness / 3; // Spread equally to R,G,B
        ledColor[i][0] += deficit;
        ledColor[i][1] += deficit;
        ledColor[i][2] += deficit;
      } else {
        deficit = minBrightness - sum;
        s2      = sum * 2;
        // Spread the "brightness deficit" back into R,G,B in proportion to
        // their individual contribition to that deficit.  Rather than simply
        // boosting all pixels at the low end, this allows deep (but saturated)
        // colors to stay saturated...they don't "pink out."
        ledColor[i][0] += deficit * (sum - ledColor[i][0]) / s2;
        ledColor[i][1] += deficit * (sum - ledColor[i][1]) / s2;
        ledColor[i][2] += deficit * (sum - ledColor[i][2]) / s2;
      }
    }

    // Apply gamma curve and place in serial output buffer
    serialData[j++] = gamma[ledColor[i][0]][0];
    serialData[j++] = gamma[ledColor[i][1]][1];
    serialData[j++] = gamma[ledColor[i][2]][2];
    // Update pixels in preview image
    preview[d].pixels[leds[i][2] * monitor[d][1] + leds[i][1]] =
     (ledColor[i][0] << 16) | (ledColor[i][1] << 8) | ledColor[i][2];
  }

  if(port != null) port.write(serialData); // Issue data to Arduino

  // Copy LED color data to prior frame array for next pass
  arraycopy(ledColor, 0, prevColor, 0, ledColor.length);
}


// CLEANUP -------------------------------------------------------------------

// The DisposeHandler is called on program exit (but before the Serial library
// is shutdown), in order to turn off the LEDs (reportedly more reliable than
// stop()).  Seems to work for the window close box and escape key exit, but
// not the 'Quit' menu option.  Thanks to phi.lho in the Processing forums.

public class DisposeHandler {
  DisposeHandler(PApplet pa) {
    pa.registerDispose(this);
  }
  public void dispose() {
    // Fill serialData (after header) with 0's, and issue to Arduino...
//    Arrays.fill(serialData, 6, serialData.length, (byte)0);
    java.util.Arrays.fill(serialData, 6, serialData.length, (byte)0);
    if(port != null) port.write(serialData);
  }
}

