import processing.serial.*;
import java.awt.*;
import java.awt.image.*;
 
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

static int brightness = 100;
static int transition = 75;  
static final int timeout = 5000; // 5 seconds

int row, col, rowOffset;
int totalWidth = 0;
int maxHeight = 0;

int[] x = new int[16], y = new int[16];
float f, range, step, start;
int[][] ledColor = new int[leds.length][3],
        prevColor = new int[leds.length][3];
byte[][] gamma = new byte[256][3];
int displays = monitor.length;
Robot[] robot = new Robot[monitor.length];
Rectangle[] bounds = new Rectangle[monitor.length],
            ledBounds;
int[][] pixelOffset = new int[leds.length][256], screenData;

byte[] serialData = new byte[6 + leds.length * 3];
Serial port;


void setup() {
  
  port = new Serial(this, Serial.list()[1], 115200);      //Open serial port, ***Check before demo***

  screenData = new int[monitor.length][];
  
  // GraphicsEnvironment and GraphicsDevice retrieve the connected monitor.
  GraphicsEnvironment graphicsE = GraphicsEnvironment.getLocalGraphicsEnvironment();
  GraphicsDevice[] devices = graphicsE.getScreenDevices();
  
  robot[0] = new Robot(devices[monitor[0][0]]);
  }
  catch(AWTException e) {
    System.out.println("Robot failed");
  }
  
  //Setting boundaries of monitor
  GraphicsConfiguration[] graphicsCon = devices[monitor[0][0]].getConfigurations();
  bounds[0]   = graphicsCon[0].getBounds();
  bounds[0].x = bounds[0].y = 0;
  totalWidth += monitor[0][1];
  if(0 > 0) totalWidth++;
  if(monitor[0][2] > maxHeight) maxHeight = monitor[0][2];



  // Determines the col and rows that get sampled for each LED
  for(int i = 0; i < leds.length; i++) {

    range = (float)bounds[leds[i][0]].width / (float)monitor[leds[i][0]][1];
    step  = range / 16.0;
    start = range * (float)leds[i][1] + step * 0.5;        //Start at the bottom-left, facing the LEDs
    
    // Columns
    for(col=0; col<16; col++){
      x[col] = (int)(start + step * (float)col);
      range = (float)bounds[leds[i][0]].height / (float)monitor[leds[i][0]][2];
    }
    
    //Rows
    step  = range / 16.0;
    start = range * (float)leds[i][2] + step * 0.5;
    for(row=0; row<16; row++){
      y[row] = (int)(start + step * (float)row);
    }
    for(row=0; row<16; row++) {
      for(col=0; col<16; col++) {
        pixelOffset[i][row * 16 + col] =
          y[row] * bounds[leds[i][0]].width + x[col];
      }
    }
  }

  for(int i = 0; i < prevColor.length; i++) {
    prevColor[i][0] = prevColor[i][1] = prevColor[i][2] =
      brightness / 3;
  }

  for(int i = 0; i < 256; i++) {
    f = pow((float)i / 255.0, 2.8);
    gamma[i][0] = (byte)(f * 255.0);
    gamma[i][1] = (byte)(f * 240.0);
    gamma[i][2] = (byte)(f * 220.0);
  }

  // Header corresponds to LEDs streaming on the Arduino.
  serialData[0] = 'M';
  serialData[1] = 'e';
  serialData[2] = 'l';
  serialData[3] = (byte)((leds.length - 1) >> 8);
  serialData[4] = (byte)((leds.length - 1) & 0xff);
  serialData[5] = (byte)(serialData[3] ^ serialData[4] ^ 0x55);
}


Serial openPort() {
  String[] ports;

  ports = Serial.list();
  return new Serial(this, ports[1], 115200);
}

void draw () {
  BufferedImage image;
  int d, i, j, o, c, weight, rb, g, sum, deficit, s2;
  int[] pixels, offset;

  // Create image from pixels read from the screen within boundaries
  // Store data from raster (rect array of pixels) in screenData 
  image = robot[0].createScreenCapture(bounds[0]);
  screenData[0] = ((DataBufferInt)image.getRaster().getDataBuffer()).getData();
    
  weight = 257 - transition;
  j = 6;

  // This section takes 256 pixels from within the block that we are looking at for each LED
  // and creates a single pixel that is the average of those colors.
  for(i=0; i<leds.length; i++) {
    d = leds[i][0];
      pixels = screenData[d];
    offset = pixelOffset[i];
    rb = g = 0;
    for(o=0; o<256; o++) {
      c   = pixels[offset[o]];
      rb += c & 0x00ff00ff;
      g  += c & 0x0000ff00;
    }

    // Blend new pixel value with prior frame
    ledColor[i][0]  = (short)((((rb >> 24) & 0xff) * weight +
                               prevColor[i][0]     * transition) >> 8);
    ledColor[i][1]  = (short)(((( g >> 16) & 0xff) * weight +
                               prevColor[i][1]     * transition) >> 8);
    ledColor[i][2]  = (short)((((rb >>  8) & 0xff) * weight +
                               prevColor[i][2]     * transition) >> 8);


    // Apply gamma curve and place in serial output buffer
    serialData[j++] = gamma[ledColor[i][0]][0];
    serialData[j++] = gamma[ledColor[i][1]][1];
    serialData[j++] = gamma[ledColor[i][2]][2];
  }
  if(port != null) port.write(serialData);           //Sending serial data to Arduino
}
