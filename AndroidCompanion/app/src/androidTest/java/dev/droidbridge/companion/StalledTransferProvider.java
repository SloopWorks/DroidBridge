package dev.droidbridge.companion;
import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.os.CancellationSignal;
import android.os.OperationCanceledException;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicIntegerArray;
import android.provider.OpenableColumns;
import java.util.*;
import java.io.*;
/** Test APK only, unexported; two nonce-scoped reliable pipes never send bytes. */
public final class StalledTransferProvider extends ContentProvider {
    private final Map<String,ParcelFileDescriptor> writers=new LinkedHashMap<>();
    private final Map<String,AtomicIntegerArray> counts=new LinkedHashMap<>();
    private synchronized AtomicIntegerArray counts(String token){
        AtomicIntegerArray value=counts.get(token);
        if(value==null){if(counts.size()>=64)counts.remove(counts.keySet().iterator().next());value=new AtomicIntegerArray(3);counts.put(token,value);}return value;
    }
    @Override public boolean onCreate(){return true;}
    private List<String> path(Uri uri){List<String> p=uri.getPathSegments();if(p.size()<2||p.size()>3||!UUID.fromString(p.get(1)).toString().equals(p.get(1)))throw new IllegalArgumentException();return p;}
    @Override public String getType(Uri uri){List<String> p=path(uri);if(!p.get(0).equals("status"))counts(p.get(1)).incrementAndGet(1);return "application/octet-stream";}
    @Override public Cursor query(Uri uri,String[] projection,String selection,String[] args,String order){return query(uri,projection,selection,args,order,null);}
    @Override public Cursor query(Uri uri,String[] projection,String selection,String[] args,String order,CancellationSignal signal){
        List<String> p=path(uri);AtomicIntegerArray values=counts(p.get(1));
        if(p.get(0).equals("notification-status")){
            android.content.SharedPreferences state=getContext().getSharedPreferences("notification-probe-"+p.get(1),0);
            int active=getContext().getSystemService(android.app.NotificationManager.class).getActiveNotifications().length;
            MatrixCursor c=new MatrixCursor(new String[]{"deliveries","reply_generation","posted_generation","active_count"});
            c.addRow(new Object[]{state.getInt("deliveries",0),state.getInt("reply_generation",0),state.getInt("posted_generation",0),active});return c;
        }
        if(p.get(0).equals("status")){int count=0;synchronized(this){for(String key:writers.keySet())if(key.contains(p.get(1)))count++;}MatrixCursor c=new MatrixCursor(new String[]{"open_pipes","query_count","type_count","open_count"});c.addRow(new Object[]{count,values.get(0),values.get(1),values.get(2)});return c;}
        values.incrementAndGet(0);
        if(p.get(0).equals("query-stall")){
            CountDownLatch gate=new CountDownLatch(1);if(signal!=null)signal.setOnCancelListener(gate::countDown);
            try{gate.await(60,TimeUnit.SECONDS);}catch(InterruptedException failure){Thread.currentThread().interrupt();}
            if(signal!=null)signal.throwIfCanceled();throw new OperationCanceledException("Synthetic query fixture budget ended");
        }
        MatrixCursor c=new MatrixCursor(new String[]{OpenableColumns.DISPLAY_NAME});c.addRow(new Object[]{p.get(0)+".bin"});return c;
    }
    @Override public synchronized ParcelFileDescriptor openFile(Uri uri,String mode)throws FileNotFoundException{
        if(!"r".equals(mode))throw new FileNotFoundException();List<String> p=path(uri);if(!p.get(0).equals("cleanup"))counts(p.get(1)).incrementAndGet(2);
        try{
            ParcelFileDescriptor[] pipe=ParcelFileDescriptor.createReliablePipe();String kind=p.get(0);
            if(kind.equals("stall")||kind.equals("query-stall")){
                if((kind.equals("stall")&&(p.size()!=3||!Arrays.asList("a","b").contains(p.get(2))))||writers.size()>=2){for(ParcelFileDescriptor fd:pipe)fd.close();throw new FileNotFoundException("Fixture full");}
                writers.put(uri.toString(),pipe[1]);
            }else if(kind.equals("small")){
                try(OutputStream out=new ParcelFileDescriptor.AutoCloseOutputStream(pipe[1])){out.write("actual provider bytes".getBytes("UTF-8"));}
            }else if(kind.equals("cleanup")){
                for(String key:new ArrayList<>(writers.keySet()))if(key.contains(p.get(1)))writers.remove(key).close();pipe[1].close();
            }else{for(ParcelFileDescriptor fd:pipe)fd.close();throw new FileNotFoundException("Unknown fixture");}
            return pipe[0];
        }catch(IOException failure){throw new FileNotFoundException(failure.toString());}
    }
    @Override public Uri insert(Uri uri,ContentValues values){throw new UnsupportedOperationException();}
    @Override public int update(Uri uri,ContentValues values,String selection,String[] args){throw new UnsupportedOperationException();}
    @Override public int delete(Uri uri,String selection,String[] args){throw new UnsupportedOperationException();}
}
