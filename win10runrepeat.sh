function goto
{
    label=$1
    cd 
    cmd=$(sed -n "/^:[[:blank:]][[:blank:]]*${label}/{:a;n;p;ba};" $0 | 
          grep -v ':$')
    eval "$cmd"
    exit
}


curl --silent --show-error http://127.0.0.1:4040/api/tunnels | sed -nE 's/.*public_url":"tcp:..([^"]*).*/\1/p' 
echo User: Hashir
echo Passwd: 264726
echo "VM can't connect? Restart Cloud Shell then Re-run script."
seq 1 86400 | while read i; do echo -en "\r Running .     $i s /86400 s";sleep 0.1;echo -en "\r Running ..    $i s /86400 s";sleep 0.1;echo -en "\r Running ...   $i s /86400 s";sleep 0.1;echo -en "\r Running ....  $i s /86400 s";sleep 0.1;echo -en "\r Running ..... $i s /86400 s";sleep 0.1;echo -en "\r Running     . $i s /86400 s";sleep 0.1;echo -en "\r Running  .... $i s /86400 s";sleep 0.1;echo -en "\r Running   ... $i s /86400 s";sleep 0.1;echo -en "\r Running    .. $i s /86400 s";sleep 0.1;echo -en "\r Running     . $i s /86400 s";sleep 0.1; done
