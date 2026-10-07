// Appends replies other people post while a thread is open. The server
// pushes each new post as the HTML of its <li>.
(() => {
  const posts = document.querySelector("ol.posts[data-live]");
  if (!posts || !("WebSocket" in window)) return;
  const scheme = location.protocol === "https:" ? "wss://" : "ws://";
  let delay = 1000;

  const connect = () => {
    const socket = new WebSocket(scheme + location.host + posts.dataset.live);
    socket.onopen = () => { delay = 1000; };
    socket.onmessage = (event) => {
      const template = document.createElement("template");
      template.innerHTML = event.data.trim();
      const post = template.content.firstElementChild;
      // Our own reply is already on the page after its redirect.
      if (post && !document.getElementById(post.id)) posts.append(post);
    };
    socket.onclose = () => {
      setTimeout(connect, delay);
      delay = Math.min(delay * 2, 30000);
    };
  };
  connect();
})();
