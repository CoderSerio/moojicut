import React from "react";

// Pure SVG scenes are shared by the static posters and the Remotion compositions.
// They illustrate supported workflows; they are not screenshots of the application.
const clamp = (v) => Math.max(0, Math.min(1, v));
const progress = (frame, start, length) => {
  const t = clamp((frame - start) / length);
  return 1 - Math.pow(1 - t, 3);
};
const icons = {
  pointer: "M5 3l14 9-7 1-3 7z",
  box: "M5 4h14v16H5z",
  arrow: "M5 19L19 5M6 5h13v13",
  text: "M4 5h16M12 5v15M8 20h8",
  cover: "M5 5h14v14H5zM5 9h14M5 15h14M9 5v14M15 5v14",
  pin: "M9 3h6l-1 7 4 4H6l4-4zM12 14v7",
  undo: "M9 5L4 10l5 5M4 10h10a6 6 0 0 1 6 6",
  check: "M5 12l4 4L19 6",
  cut: "M8 8l12 12M8 16L20 4M4 4a3 3 0 1 0 0 6 3 3 0 0 0 0-6M4 14a3 3 0 1 0 0 6 3 3 0 0 0 0-6",
  play: "M7 4l13 8-13 8z",
  copy: "M8 8h12v12H8zM16 8V4H4v12h4",
};
export function Icon({
  name,
  x = 0,
  y = 0,
  size = 22,
  color = "currentColor",
}) {
  return (
    <svg
      x={x}
      y={y}
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke={color}
      strokeWidth="1.7"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <path d={icons[name] || icons.pointer} />
    </svg>
  );
}
function Text({
  x,
  y,
  children,
  size = 16,
  fill = "#262930",
  weight = 400,
  ...props
}) {
  return (
    <text
      x={x}
      y={y}
      fontSize={size}
      fill={fill}
      fontWeight={weight}
      {...props}
    >
      {children}
    </text>
  );
}
function Dots({ x = 24, y = 23, dark = false }) {
  return (
    <g fill={dark ? "#4b4c52" : "#d9dce1"}>
      {[0, 16, 32].map((v) => (
        <circle key={v} cx={x + v} cy={y} r="4.5" />
      ))}
    </g>
  );
}
function Wallpaper({ id, x = 0, y = 0, width = 1000, height = 560 }) {
  return (
    <svg
      x={x}
      y={y}
      width={width}
      height={height}
      viewBox="0 0 1000 560"
      preserveAspectRatio="xMidYMid slice"
    >
      <defs>
        <linearGradient id={`${id}-bg`} x1="0" x2="1" y2="1">
          <stop stopColor="#151d4e" />
          <stop offset=".45" stopColor="#7081ce" />
          <stop offset="1" stopColor="#c7d6f4" />
        </linearGradient>
        <linearGradient id={`${id}-fold`} x1="0" y1="1" x2=".7" y2="0">
          <stop stopColor="#18295f" />
          <stop offset=".6" stopColor="#99abed" />
          <stop offset="1" stopColor="#e5e9fc" />
        </linearGradient>
        <linearGradient id={`${id}-light`} x1="0" x2="1">
          <stop stopColor="#8194da" />
          <stop offset="1" stopColor="#e9eafd" />
        </linearGradient>
      </defs>
      <path fill={`url(#${id}-bg)`} d="M0 0h1000v560H0z" />
      <path
        fill={`url(#${id}-fold)`}
        d="M310-100C130 220 600 215 150 660h700C1260 190 570 260 820-100Z"
      />
      <path
        fill={`url(#${id}-light)`}
        d="M600-100C320 240 1010 180 460 660h135C1120 200 510 240 795-100Z"
      />
      <path
        fill="none"
        stroke="#fff"
        strokeOpacity=".4"
        d="M600-100C320 240 1010 180 460 660"
      />
    </svg>
  );
}
function Project({
  x = 130,
  y = 82,
  width = 740,
  height = 380,
  id = "project",
}) {
  return (
    <g transform={`translate(${x},${y})`}>
      <rect width={width} height={height} rx="12" fill="white" />
      <path
        d={`M12 0h${width - 24}q12 0 12 12v30H0V12Q0 0 12 0`}
        fill="#f8f9fb"
      />
      <Dots />
      <Text x={width / 2} y={27} size={12} fill="#8a8e97" textAnchor="middle">
        studio / a little room to think
      </Text>
      <Text
        x={38}
        y={89}
        size={12}
        fill="#8b8e9a"
        weight={600}
        letterSpacing="2"
      >
        FIELDNOTES
      </Text>
      <Text x={38} y={140} size={36} weight={600} letterSpacing="-1.4">
        Make space for
      </Text>
      <Text x={38} y={181} size={36} weight={600} letterSpacing="-1.4">
        your next idea.
      </Text>
      <Text x={38} y={219} size={13} fill="#82858e">
        A quieter place to do your best work.
      </Text>
      <rect x="38" y="246" width="110" height="34" rx="7" fill="#272931" />
      <Text x={93} y={268} size={12} fill="#fff" textAnchor="middle">
        Explore spaces ↗
      </Text>
      <svg
        x={width - 300}
        y="66"
        width="265"
        height={height - 94}
        viewBox="0 0 265 286"
      >
        <defs>
          <linearGradient id={`${id}-arch`} x2="1" y2="1">
            <stop stopColor="#ded9d2" />
            <stop offset="1" stopColor="#aaa6a2" />
          </linearGradient>
        </defs>
        <rect width="265" height="286" rx="7" fill="#e9e6e0" />
        <path d="M35 286V109a97 97 0 0 1 194 0v177" fill={`url(#${id}-arch)`} />
        <path d="M73 286V116a59 59 0 0 1 118 0v170" fill="#f5f2ea" />
        <path
          d="M73 286V116a59 59 0 0 1 118 0v170"
          fill="none"
          stroke="#a5a19b"
        />
        <ellipse cx="143" cy="272" rx="58" ry="9" fill="#c6c1b7" />
        <path d="M109 260l8-68h43l9 68z" fill="#acb79c" />
        <ellipse cx="139" cy="192" rx="22" ry="7" fill="#c6d0b8" />
        <path
          d="M139 187c-22-33-36-53-28-71 22 9 27 27 28 48 1-38 22-65 38-66 4 28-23 65-38 79"
          fill="#727e69"
        />
      </svg>
    </g>
  );
}
function Toolbar({ x = 319, y = 448, active = "arrow" }) {
  const tools = [
    "pointer",
    "box",
    "arrow",
    "text",
    "cover",
    "pin",
    "undo",
    "copy",
    "check",
  ];
  return (
    <g transform={`translate(${x},${y})`}>
      <rect width="360" height="46" rx="12" fill="#26272d" stroke="#ffffff30" />
      {tools.map((name, i) => (
        <g key={name} transform={`translate(${10 + i * 38},8)`}>
          {name === active && (
            <rect width="30" height="30" rx="6" fill="#50525c" />
          )}
          <Icon
            name={name}
            x={5}
            y={5}
            size={20}
            color={name === "check" ? "#d8dcef" : "#f3f3f5"}
          />
        </g>
      ))}
    </g>
  );
}
function Cursor({ x, y }) {
  return (
    <g transform={`translate(${x},${y})`}>
      <path
        d="M0 0l6 28 7-9 12-2z"
        fill="#fff"
        stroke="#262930"
        strokeWidth="2"
      />
      <rect x="20" y="28" width="57" height="25" rx="6" fill="#282b35" />
      <Text x={48} y={45} size={11} fill="#fff" textAnchor="middle">
        You
      </Text>
    </g>
  );
}
function Capture({ frame, id }) {
  const selection = progress(frame, 8, 30);
  const arrow = progress(frame, 50, 28);
  const copied = progress(frame, 145, 15) * (1 - progress(frame, 215, 12));
  return (
    <>
      <Wallpaper id={id} />
      <Project id={id} />
      <path
        fill="#11152c"
        opacity={0.28 * selection}
        fillRule="evenodd"
        d="M0 0h1000v560H0z M151 143h696v264H151z"
      />
      <g opacity={selection}>
        <rect
          x="151"
          y="143"
          width="696"
          height="264"
          rx="2"
          fill="none"
          stroke="#fff"
          strokeWidth="1.5"
        />
        {[
          [151, 143],
          [847, 143],
          [151, 407],
          [847, 407],
        ].map(([x, y]) => (
          <rect
            key={`${x}-${y}`}
            x={x - 3}
            y={y - 3}
            width="6"
            height="6"
            fill="white"
          />
        ))}
        <rect x="151" y="114" width="81" height="23" rx="5" fill="#252834" />
        <Text x={191} y={130} size={11} fill="white" textAnchor="middle">
          696 × 264
        </Text>
        <g opacity={arrow}>
          <path
            d="M493 330Q501 255 578 254"
            fill="none"
            stroke="#f17473"
            strokeWidth="6"
            strokeLinecap="round"
            strokeDasharray="150"
            strokeDashoffset={150 * (1 - arrow)}
          />
          <path
            d="M561 242l18 12-16 15"
            fill="none"
            stroke="#f17473"
            strokeWidth="6"
            strokeLinecap="round"
            strokeLinejoin="round"
          />
        </g>
        <Toolbar />
      </g>
      <Cursor x={492 + 104 * arrow} y={328 - 58 * arrow} />
      <g opacity={copied} transform={`translate(0,${10 * (1 - copied)})`}>
        <rect x="390" y="42" width="220" height="41" rx="10" fill="#fff" />
        <Icon name="check" x={405} y={52} size={20} />
        <Text x={440} y={68} size={14} weight={500}>
          Copied to clipboard
        </Text>
      </g>
    </>
  );
}
function Pin({ frame, id }) {
  const pin = progress(frame, 20, 45);
  return (
    <>
      <Wallpaper id={id} />
      <g transform="translate(150,50)">
        <rect width="690" height="460" rx="12" fill="#fff" />
        <Dots />
        <path d="M0 44h690" stroke="#eceef0" />
        <Text x={280} y={27} size={12} fill="#93969c">
          Your next great idea
        </Text>
        <rect x="0" y="45" width="170" height="415" fill="#f7f8fa" />
        <Text x={24} y={85} size={13} weight={600}>
          Workspace
        </Text>
        {["Overview", "Design notes", "References"].map((t, i) => (
          <Text
            key={t}
            x={28}
            y={126 + i * 37}
            size={12}
            fill={i === 1 ? "#262930" : "#8b8e96"}
          >
            {t}
          </Text>
        ))}
        <Text x={207} y={108} size={29} weight={600} letterSpacing="-.8">
          Less switching.
        </Text>
        <Text x={207} y={145} size={29} weight={600} letterSpacing="-.8">
          More making.
        </Text>
        {[220, 252, 284, 341, 373].map((y, i) => (
          <rect
            key={y}
            x="209"
            y={y}
            width={i % 2 ? 310 : 365}
            height="7"
            rx="3.5"
            fill="#e9ebef"
          />
        ))}
      </g>
      <g
        transform={`translate(${60 + 20 * (1 - pin)},${216 + 18 * (1 - pin)})`}
        opacity={pin}
      >
        <rect
          x="-8"
          y="-8"
          width="360"
          height="240"
          rx="15"
          fill="#161d40"
          opacity=".15"
        />
        <rect width="344" height="224" rx="10" fill="#fff" />
        <svg
          x="0"
          y="0"
          width="344"
          height="196"
          viewBox="148 140 700 265"
          preserveAspectRatio="xMidYMid slice"
        >
          <Project x={130} y={82} id={`${id}-ref`} />
        </svg>
        <path d="M0 196h344" stroke="#e7e8ee" />
        <Icon name="pin" x={13} y={201} size={16} />
        <Text x={36} y={214} size={10} fill="#737782">
          Pinned reference
        </Text>
        <Text x={307} y={214} size={11} fill="#737782">
          100%
        </Text>
      </g>
      <Cursor x={380 - 45 * pin} y={430 - 24 * pin} />
    </>
  );
}
function Edit({ frame, id }) {
  const split = progress(frame, 45, 20);
  const gap = 18 * progress(frame, 80, 24) * (1 - progress(frame, 140, 24));
  const head = 100 + 690 * clamp(frame / 230);
  return (
    <>
      <rect width="1000" height="560" fill="#191a1e" />
      <Dots dark />
      <Text x={500} y={29} size={12} fill="#8c8e96" textAnchor="middle">
        Mooji Cut · Video editor
      </Text>
      <rect x="887" y="12" width="93" height="27" rx="7" fill="#e9e9ef" />
      <Text x={933} y={30} size={11} textAnchor="middle" weight={600}>
        Save video ↗
      </Text>
      <rect x="20" y="53" width="960" height="298" rx="8" fill="#101114" />
      <Wallpaper x={236} y={53} width={528} height={298} id={id} />
      <g transform="translate(236,53) scale(.528)">
        <Project id={`${id}-preview`} />
      </g>
      <Text x={26} y={382} size={12} fill="#b6b8c0">
        00:{String(Math.floor(frame / 30)).padStart(2, "0")}.000
      </Text>
      <Text x={115} y={382} size={12} fill="#636772">
        / 00:08.000
      </Text>
      <Text x={442} y={382} size={16} fill="#b5b7bf">
        ‹‹
      </Text>
      <Icon name="play" x={490} y={366} size={22} color="#dddfe7" />
      <Text x={540} y={382} size={16} fill="#b5b7bf">
        ››
      </Text>
      <Text x={930} y={382} size={12} fill="#c1c3cc">
        1×
      </Text>
      <path d="M20 401h960" stroke="#32343c" />
      <Icon name="cut" x={25} y={413} size={18} color="#989ca9" />
      <Icon name="undo" x={58} y={413} size={18} color="#989ca9" />
      {Array.from({ length: 9 }, (_, i) => (
        <g key={i}>
          <Text x={100 + i * 99} y={427} size={10} fill="#6d717f">
            {i}s
          </Text>
          <path d={`M${100 + i * 99} 434v5`} stroke="#484b55" />
        </g>
      ))}
      <Text x={25} y={469} size={11} fill="#888d9b">
        V1
      </Text>
      <Text x={25} y={518} size={11} fill="#888d9b">
        A1
      </Text>
      <rect
        x="98"
        y="445"
        width={692}
        height="42"
        rx="5"
        fill="#454954"
        stroke="#747b8e"
      />
      <Text x={113} y={471} size={11} fill="#eceef5">
        Screen recording
      </Text>
      <g opacity={split}>
        <rect
          x={390 + gap}
          y="445"
          width="400"
          height="42"
          rx="5"
          fill="#575d6c"
          stroke="#a2a9ba"
        />
        <Text x={410 + gap} y={471} size={11} fill="#eceef5">
          Screen recording · 2
        </Text>
        <rect x="388" y="444" width={2 + gap} height="45" fill="#191a1e" />
      </g>
      <rect x="98" y="496" width="692" height="35" rx="5" fill="#343a45" />
      <g stroke="#959fb5" strokeWidth="2" opacity=".8">
        {Array.from({ length: 167 }, (_, i) => {
          const h = 3 + Math.abs(Math.sin(i * 1.7) * Math.cos(i * 0.19)) * 20;
          return <path key={i} d={`M${107 + i * 4} ${513 - h / 2}v${h}`} />;
        })}
      </g>
      <path d={`M${head} 436v101`} stroke="#f0f0f5" strokeWidth="1.5" />
      <path d={`M${head - 4} 433h8v7l-4 4-4-4z`} fill="#f0f0f5" />
      <g opacity={progress(frame, 160, 15)}>
        <rect
          x="823"
          y="448"
          width="141"
          height="76"
          rx="8"
          fill="#272a32"
          stroke="#454954"
        />
        <Text x={836} y={472} size={10} fill="#9298a8">
          CLIP SPEED
        </Text>
        <Text x={836} y={508} size={26} weight={500} fill="#f4f4f6">
          2.0×
        </Text>
      </g>
    </>
  );
}
export function Scene({ kind = "capture", frame = 110 }) {
  const id = `demo-${kind}`;
  return (
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 1000 560"
      width="100%"
      height="100%"
      style={{
        display: "block",
        fontFamily:
          "Inter, -apple-system, BlinkMacSystemFont, Segoe UI, sans-serif",
      }}
    >
      {kind === "pin" ? (
        <Pin frame={frame} id={id} />
      ) : kind === "edit" ? (
        <Edit frame={frame} id={id} />
      ) : (
        <Capture frame={frame} id={id} />
      )}
    </svg>
  );
}
