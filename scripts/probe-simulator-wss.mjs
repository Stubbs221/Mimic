//
//  probe-simulator-wss.mjs
//  Mimic development tools
//
//  Created by Василий Маслов on 07.10.2026.
import {createServer} from 'node:https';
import {readFile,stat} from 'node:fs/promises';
import {createHash} from 'node:crypto';

// Explicit developer invocation only. This probe never reads a simulator or installs trust.
const [certificatePath,keyPath]=process.argv.slice(2);
if(!certificatePath||!keyPath)throw new Error('Usage: node scripts/probe-simulator-wss.mjs certificate.pem private-key.pem');
if((await stat(keyPath)).mode&0o077)throw new Error('Private key must be accessible only by its owner');
const server=createServer({cert:await readFile(certificatePath),key:await readFile(keyPath),minVersion:'TLSv1.2'},(_request,response)=>{response.writeHead(404);response.end();});
server.maxConnections=8;server.requestTimeout=5000;server.headersTimeout=5000;server.maxHeadersCount=32;
let handshakes=0;
server.on('tlsClientError',()=>console.log(JSON.stringify({event:'tlsRejected'})));
server.on('upgrade',(request,socket)=>{
 const key=request.headers['sec-websocket-key'];
 if(request.url!=='/'||request.headers.upgrade?.toLowerCase()!=='websocket'||request.headers['sec-websocket-version']!=='13'||typeof key!=='string'||!/^[a-zA-Z0-9+/]{22}==$/.test(key)){socket.destroy();return;}
 const accept=createHash('sha1').update(key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
 socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
 const message=Buffer.from('mimic-wss-probe-v1');socket.write(Buffer.concat([Buffer.from([0x81,message.length]),message]));
 socket.setTimeout(5000,()=>socket.destroy());socket.on('error',()=>{});socket.on('data',()=>socket.end(Buffer.from([0x88,0])));
 console.log(JSON.stringify({event:'websocketHandshake',count:++handshakes}));
});
server.listen(47931,'127.0.0.1',()=>console.log(JSON.stringify({event:'ready',origin:'wss://127.0.0.1:47931',expiresSeconds:600})));
const stop=()=>{server.close();server.closeAllConnections();process.exit(0);};
setTimeout(stop,600000);process.once('SIGTERM',stop);process.once('SIGINT',stop);
