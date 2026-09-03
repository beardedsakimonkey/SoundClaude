import fragmentShaderSource from "../shaders/audioVisualizer.frag?raw";
import vertexShaderSource from "../shaders/audioVisualizer.vert?raw";

export interface VisualizerRenderer {
  destroy: () => void;
  render: (frequencyData: Uint8Array<ArrayBuffer>, timeMilliseconds: number) => void;
}

function createShader(gl: WebGLRenderingContext, type: number, source: string) {
  const shader = gl.createShader(type);
  if (!shader) return null;

  gl.shaderSource(shader, source);
  gl.compileShader(shader);
  if (gl.getShaderParameter(shader, gl.COMPILE_STATUS)) return shader;

  gl.deleteShader(shader);
  return null;
}

export function createVisualizerRenderer(canvas: HTMLCanvasElement): VisualizerRenderer | null {
  const gl = canvas.getContext("webgl", {
    alpha: true,
    antialias: false,
    depth: false,
    powerPreference: "low-power",
  });
  if (!gl) return null;
  const context = gl;

  const vertexShader = createShader(context, context.VERTEX_SHADER, vertexShaderSource);
  const fragmentShader = createShader(context, context.FRAGMENT_SHADER, fragmentShaderSource);
  if (!vertexShader || !fragmentShader) {
    if (vertexShader) gl.deleteShader(vertexShader);
    if (fragmentShader) gl.deleteShader(fragmentShader);
    return null;
  }

  const program = gl.createProgram();
  if (!program) {
      context.deleteShader(vertexShader);
      context.deleteShader(fragmentShader);
    return null;
  }

  gl.attachShader(program, vertexShader);
  gl.attachShader(program, fragmentShader);
  gl.linkProgram(program);
  gl.deleteShader(vertexShader);
  gl.deleteShader(fragmentShader);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
    gl.deleteProgram(program);
    return null;
  }

  const positionBuffer = gl.createBuffer();
  const audioTexture = gl.createTexture();
  const positionLocation = gl.getAttribLocation(program, "a_position");
  if (!positionBuffer || !audioTexture || positionLocation < 0) {
    if (positionBuffer) gl.deleteBuffer(positionBuffer);
    if (audioTexture) gl.deleteTexture(audioTexture);
    gl.deleteProgram(program);
    return null;
  }

  gl.bindBuffer(gl.ARRAY_BUFFER, positionBuffer);
  gl.bufferData(
    gl.ARRAY_BUFFER,
    new Float32Array([-1, -1, 3, -1, -1, 3]),
    gl.STATIC_DRAW,
  );

  gl.bindTexture(gl.TEXTURE_2D, audioTexture);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);

  const resolutionLocation = gl.getUniformLocation(program, "u_resolution");
  const energyLocation = gl.getUniformLocation(program, "u_energy");
  const timeLocation = gl.getUniformLocation(program, "u_time");
  gl.useProgram(program);
  gl.uniform1i(gl.getUniformLocation(program, "u_audio"), 0);
  gl.enableVertexAttribArray(positionLocation);
  gl.vertexAttribPointer(positionLocation, 2, gl.FLOAT, false, 0, 0);
  let textureWidth = 0;

  function resizeCanvas() {
    const pixelRatio = Math.min(window.devicePixelRatio, 1);
    const width = Math.max(1, Math.floor(canvas.clientWidth * pixelRatio));
    const height = Math.max(1, Math.floor(canvas.clientHeight * pixelRatio));
    if (canvas.width !== width || canvas.height !== height) {
      canvas.width = width;
      canvas.height = height;
    }
    context.viewport(0, 0, width, height);
  }

  return {
    destroy() {
      gl.deleteBuffer(positionBuffer);
      gl.deleteTexture(audioTexture);
      gl.deleteProgram(program);
    },
    render(frequencyData, timeMilliseconds) {
      resizeCanvas();

      let energy = 0;
      for (const value of frequencyData) energy += value;
      energy /= frequencyData.length * 255;

      gl.useProgram(program);
      gl.activeTexture(gl.TEXTURE0);
      gl.bindTexture(gl.TEXTURE_2D, audioTexture);
      if (textureWidth !== frequencyData.length) {
        gl.texImage2D(
          gl.TEXTURE_2D,
          0,
          gl.LUMINANCE,
          frequencyData.length,
          1,
          0,
          gl.LUMINANCE,
          gl.UNSIGNED_BYTE,
          frequencyData,
        );
        textureWidth = frequencyData.length;
      } else {
        gl.texSubImage2D(
          gl.TEXTURE_2D,
          0,
          0,
          0,
          frequencyData.length,
          1,
          gl.LUMINANCE,
          gl.UNSIGNED_BYTE,
          frequencyData,
        );
      }
      gl.uniform2f(resolutionLocation, canvas.width, canvas.height);
      gl.uniform1f(energyLocation, energy);
      gl.uniform1f(timeLocation, timeMilliseconds / 1000);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
    },
  };
}
