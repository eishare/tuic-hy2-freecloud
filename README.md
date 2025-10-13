# 1.TUIC在Freecloud部署

* Freecloud/Natfreecloud/Runfreecloud一键极简部署TUIC节点

* 必须在一键脚本末尾添加自定义端口

```
curl -Ls https://raw.githubusercontent.com/eishare/tuic-hy2-freecloud/main/tuic.sh | sed 's/\r$//' | bash -s -- 
```
